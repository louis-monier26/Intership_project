# Intership_project


# MMM Influencers – Modélisation & Optimisation de Budget par Tier

Pipeline complet de **Marketing Mix Modeling (MMM)** appliqué aux campagnes d'influence, permettant de :
1. Extraire et nettoyer les données de posts d'influenceurs depuis BigQuery
2. Construire des jeux de données hebdomadaires agrégés par tier d'influenceur
3. Entraîner des modèles MMM (via **Robyn**) pour expliquer les **engagements** et les **vues**
4. Extraire les courbes de réponse (Hill functions avec adstock géométrique)
5. Optimiser l'allocation budgétaire multi-objectifs entre tiers via **NSGA3** (pymoo)

---


# Pipeline Détaillé – MMM Influenceurs

Ce document décrit étape par étape le pipeline de traitement, modélisation et optimisation.

---

## 1. Extraction des données (BigQuery)

**Fonction** : `get_posts_data(force_refresh=False)`

**Objectif** : récupérer les données brutes de posts d'influenceurs depuis BigQuery, avec mise en cache locale.

**Fonctionnement** :
- Si un fichier cache `full_posts_data_4.pkl` existe et que `force_refresh=False` → chargement direct depuis le disque (rapide, pas de coût BigQuery).
- Sinon → exécution de la requête SQL contenue dans `full_posts.sql` via le client `bigquery.Client(project=project_id)`, puis sauvegarde du résultat en `.pkl`.

**Paramètres clés** :
- `project_id = 'emea-dataexzone-gbl-emea-pd'`
- Requête SQL externalisée dans `/home/user/mmm_influencers/source_documents/full_posts.sql`


---

## 2. Préparation de la variable "vues totales"

```python
python full_posts['story_views'] = pd.to_numeric(full_posts['story_views'], errors='coerce') full_posts['video_views'] = pd.to_numeric(full_posts['video_views'], errors='coerce') full_posts['total_views'] = full_posts['story_views'].fillna(0) + full_posts['video_views'].fillna(0)
```


**Objectif** : la donnée `total_views` n'existe pas nativement — elle est reconstruite en sommant les vues de story et les vues vidéo (en traitant les valeurs manquantes comme 0).

---

## 3. Nettoyage des outliers

**Fonction** : `clean_post_data(df)`

**Colonnes requises** : `tier`, `post_cost`, `eng_rate`

**Logique** (appliquée **par tier**, pas globalement) :
1. Calcul des percentiles 5 % et 95 % du `post_cost`
2. Calcul du percentile 95 % de `eng_rate`
3. Filtrage : on conserve uniquement les posts dont
   - `post_cost` ∈ [Q05, Q95]
   - `eng_rate` ≤ Q95

**Pourquoi par tier ?** Les coûts et taux d'engagement varient énormément selon le tier (Nano vs VIP) — un seuil global écraserait les extrêmes légitimes des petits tiers.

**Gestion d'erreurs** : lève une `ValueError` si les colonnes requises sont absentes, ou une `RuntimeError` en cas d'échec du filtrage.

---

## 4. Construction du dataset MMM hebdomadaire

### 4.1 Définition de la semaine

```python

df_mmm['time'] = df_mmm['post_date'].dt.to_period('W-MON').dt.start_time
``` 
Chaque post est rattaché à sa semaine (démarrant le lundi). Un index numérique week_index est aussi calculé à partir du lundi de référence (première semaine du dataset).

### 4.2 Variable de contrôle : influenceurs actifs

```python
active_influ_df = df_mmm.groupby(['time','week_index','country','category'])['influencer_id'].nunique()
``` 
Compte le nombre d'influenceurs uniques actifs par semaine/pays/catégorie. Utilisé comme variable de contrôle dans le MMM pour capter l'effet de la croissance du pool d'influenceurs dans le temps (identifiée en EDA).

### 4.3 Variables cibles
`total_eng_df` : somme des engagements par semaine/pays/catégorie
`total_views_df` : somme des total_views par semaine/pays/catégorie

### 4.4 Dépenses par tier (pivot)
```python
mmm_input = df_mmm.pivot_table(
    index=['time','week_index','country','category'],
    columns='tier', values='post_cost', aggfunc='sum', fill_value=0
)
``` 
Résultat : une colonne Spend_<tier> par tier (ex : Spend_1-Nano, Spend_2-Micro, ...).


### 4.5 Fusion
Les 3 tables (dépenses, engagements, vues, influenceurs actifs) sont fusionnées sur ['time','week_index','country','category'].

### 4.6 Agrégation géographique et catégorielle
Deux niveaux d'agrégation successifs :

Par pays (mmm_input_country) : somme des métriques par time/week_index/country
Niveau global (mmm_global) : somme sur time uniquement, tous pays/catégories confondus
Traitement des zéros de dépense :

```python
mmm_global[spend_cols] = mmm_global[spend_cols].replace(0, 1)
```
Les dépenses nulles sont remplacées par 1€ — probablement pour éviter des divisions par zéro plus loin (CPE/CPV, courbes de Hill). 

### 4.7 Sorties finales
```python
mmm_eng_input = mmm_global sans total_views
mmm_views_input = mmm_global sans total_eng
```

max_tiers : liste des dépenses hebdomadaires maximales observées, par tier — utilisée plus tard pour borner les courbes de réponse.
### 5. Agrégation de performance par influenceur et par tier
### 5.1 Niveau influenceur : posts_to_influ(df)
Regroupement par `['influencer_id','platform','deliverable_type']`, calcul de :

`avg_cost_eur, avg_eng_rate` (moyennes)
`total_cost, total_eng, total_views` (sommes)
nb_posts (somme des posts contractés)
Dédoublonnage sur la clé de groupe (drop_duplicates), colonnes descriptives conservées (country, tier, category, etc.).

### 5.2 Niveau tier : influ_to_tiers(df_influ)
Agrégation par tier :

`nb_createurs_uniques` : nombre d'influenceurs distincts
`total_spent_eur, total_eng, total_views, total_posts_delivered` : sommes
`median_cost_per_post` : médiane des coûts moyens par influenceur
`avg_engagement_rate` : moyenne des taux d'engagement moyens
`CPE_global = total_spent_eur / total_eng` (coût par engagement)
`CPV_global = total_spent_eur / total_views` (coût par vue)
→ Résultat : tiers_data, la table de référence par tier, enrichie ensuite avec max_spend (issu de l'étape 4.7).

### 6. Modélisation MMM avec Robyn
Le pipeline exécute deux modélisations séparées et symétriques : une pour les engagements, une pour les vues. Détail pour les engagements (identique pour les vues) :

### 6.1 Chargement des données d'entrée
```python
dt_weekly_eng = pd.read_csv(".../eng_mmm_input_data.csv")
dt_weekly_eng.rename(columns={'total_eng': 'dep_var'})
```
Variable cible renommée en `dep_var` (convention Robyn)
Nettoyage des colonnes techniques (Unnamed: 0, espaces dans les noms)
### 6.2 Spécification du modèle

```python
MMMData.MMMDataSpec(
    dep_var="dep_var", dep_var_type="revenue", date_var="time",
    context_vars=["active_influencer_count"],
    paid_media_spends=paid_media_columns,
    paid_media_vars=paid_media_columns,
    window_start=start_date, window_end=end_date
)
paid_media_columns = les 6 canaux de dépense par tier (Nano_spend, Micro_spend, ..., VIP_spend)
context_vars = variable de contrôle (nb d'influenceurs actifs)
dep_var_type="revenue" : traité comme une variable continue à maximiser (pas une conversion binaire)
```
### 6.3 Données de saisonnalité (Prophet)

```python
HolidaysData(dt_holidays=dt_prophet_holidays,
             prophet_vars=["trend","season","holiday"],
             prophet_country="ES", prophet_signs=["default"]*3)
```
Le pays "ES" est choisi car il concentre le plus grand nombre de posts dans le dataset — les effets de saisonnalité/jours fériés espagnols serviront de proxy pour l'ensemble du portefeuille.

### 6.4 Hyperparamètres (adstock géométrique)
Pour chaque canal, une plage de recherche est définie :

`alphas` : forme de la courbe de Hill (concavité)
`gammas` : point d'inflexion (en % du spend max)
`thetas` : taux de rétention de l'adstock (mémoire d'une semaine sur l'autre)
`lambda_` : régularisation Ridge
`train_size` : proportion train/test
### 6.5 Entraînement
```python
robyn_eng.feature_engineering()
robyn_eng.train_models(
    trials_config=TrialsConfig(iterations=4000, trials=5),
    ts_validation=True, add_penalty_factor=False,
    rssd_zero_penalty=True, nevergrad_algo=NevergradAlgorithm.TWO_POINTS_DE,
    model_name=Models.RIDGE
)
```
5 essais indépendants × 4000 itérations d'optimisation bayésienne (Nevergrad)

Pénalité RSSD pour favoriser des contributions de canaux réalistes
### 6.6 Clustering et sélection du meilleur modèle
```python
ClusteringConfig(cluster_by=ClusterBy.HYPERPARAMETERS, max_clusters=10, min_clusters=3)
robyn_eng.evaluate_models(cluster_config=configs)
```
Regroupe les solutions du front de Pareto par similarité d'hyperparamètres, pour identifier des familles de modèles robustes plutôt qu'un optimum isolé potentiellement instable.

Score de sélection final :

```python
df_hyp_eng['best'] = 0.9 * df_hyp_eng['rsq_test'] + 0.1 * (1 - df_hyp_eng['decomp.rssd'])
best_model_eng = df_hyp_eng.loc[df_hyp_eng['best'].idxmax()]
```

→ Compromis 90 % qualité prédictive (`R²` test) / 10 % cohérence business (decomp.rssd).

### 6.7 Extraction des coefficients par tier
Pour chaque tier, récupération dans le meilleur modèle :

`alpha_eng, gamma_pct_eng, theta_eng` (hyperparamètres de la courbe de Hill et de l'adstock)
coef_eng (coefficient de contribution linéaire, depuis `df_agg_eng / x_decomp_agg`)
Ces valeurs sont injectées dans tiers_data.

### 6.8 Visualisation des courbes de réponse
Pour chaque canal, tracé de la fonction de Hill :

```python
def get_hill_curve(spend_array, alpha, gamma_abs, coef):
    return coef * (spend_array**alpha) / (spend_array**alpha + gamma_abs**alpha + 1e-9)
gamma_abs = gamma_pct × max_spend
```
(le gamma est ramené en valeur absolue à partir du % et de la dépense hebdomadaire maximale historique du tier)
Plage de spend testée : `[0, 1.5 × max_spend]`
Répété à l'identique pour les vues (section 7 du code), avec son propre modèle Robyn (`robyn_views`), ses propres coefficients (`alpha_views, gamma_pct_views, theta_views, coef_views`).

### 7. Optimisation multi-objectifs (NSGA3)
### 7.1 Préparation des inputs numériques
Extraction en numpy.array de tous les coefficients par tier :

`unit_costs`, `unit_eng_rate` (coûts médians et taux d'engagement observés)
`alpha_views`, `gamma_views_abs`, `coef_views`, `theta_views`
`alpha_eng`, `gamma_eng_abs`, `coef_eng`, `theta_eng`
Constantes de campagne :

```python
CAMPAIGN_BUDGET = 100000.0
CAMPAIGN_WEEKS = 4
```
### 7.2 Le problème d'optimisation : TierPortfolioProblem(Problem)
Variables de décision : une part budgétaire par tier actif (selected_tiers), bornée [0.01, 1.0].

Étapes de l'évaluation (_evaluate) pour chaque individu de la population :

Reconstruction du vecteur complet (6 tiers) à partir des seuls tiers actifs
Normalisation pour que la somme des parts = 1 (100 % du budget)
Calcul du budget par tier : `budget_per_tier = x_full × campaign_budget`
Taux d'engagement portefeuille : moyenne pondérée par le nombre de posts achetables par tier (budget / coût médian)
Adstock géométrique hebdomadaire appliqué séparément pour vues et engagements, sur CAMPAIGN_WEEKS semaines :
`accum(w) = spend(w) + theta × accum(w-1)`
Application de la courbe de Hill sur le spend adstické, semaine par semaine, puis somme sur toute la campagne → portfolio_views, portfolio_engagements
Calcul du CPE et CPV portefeuille (avec garde-fou à 999 si dénominateur nul)
6 fonctions objectif retournées (out["F"]) :

Index &	Objectif & Sens
- 0	`	coût réel - budget cible
- 1	-portfolio_views	maximiser les vues
- 2	-portfolio_engagements	maximiser les engagements
- 3	-portfolio_eng_rate	maximiser le taux d'engagement
- 4	portfolio_cpe	minimiser le coût par engagement
- 5	portfolio_cpv	minimiser le coût par vue
### 7.3 Configuration de l'algorithme
```python
ref_dirs = get_reference_directions("energy", 6, n_points=160)
algorithm = NSGA3(ref_dirs=ref_dirs, sampling=FloatRandomSampling(),
                   crossover=SBX(prob=0.9, eta=20), mutation=PM(prob=0.9, eta=20),
                   pop_size=80)
res = minimize(problem, algorithm, termination=('n_gen', 150), seed=42)
```

6 directions de référence (une par objectif) générées par la méthode "energy"
Population de 80 individus, 150 générations
Croisement SBX + mutation polynomiale (opérateurs standards pour variables continues)
### 7.4 Post-traitement des résultats

```python
X_opt, F_opt = res.X, res.F
```
Pour chaque solution du front de Pareto final :

Renormalisation des parts budgétaires `(x_opt / sum(x_opt))`
Reconversion des objectifs (signe inversé pour vues/engagements/taux)
Construction de df_strategies : un tableau comparatif des stratégies candidates avec leur budget par tier (%) et leurs KPIs attendus (vues, engagements, taux d'engagement, CPE, CPV)
→ Sortie finale : df_strategies, une liste de compromis budgétaires équivalents au sens de Pareto, à arbitrer selon les priorités business (volume vs efficience vs coût).



