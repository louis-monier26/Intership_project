WITH FilteredPosts AS (
        SELECT DISTINCT
            i.influencer_id,
            ppo.post_id,
            ppo.channel_id,
            i.influencer_name,
            ppo.channel_name AS influenceur_pseudo,
            campaign_name,
            p.platform,
            ppo.reach AS reach,
            zone,
            signature AS signature,
            division,
            category AS categories,
            po.post_type_contracted AS post_type,
            ppo.deliverable_type,
            ppo.post_date AS post_date,
            po.posts_contracted,
            po.content_fees_eur,
            po.content_fees,
            ppo.post_title,
            ppo.video_views,
            ppo.video_plays,
            ppo.engagements,
            ppo.likes,
            ppo.comments,
            ppo.potential_reach,
            ppo.story_views,
            ppo.total_video_views,
            CASE
            WHEN source_country = 'Baltics' THEN 'Latvia,Lithuania,Estonia'
            WHEN source_country = 'Benelux' THEN 'Belgium,Netherlands,Luxembourg'
            WHEN source_country = 'Nordics' THEN 'Sweden,Finland,Norway,Denmark,Iceland'
            ELSE source_country
            END AS country_map,
            CASE
            WHEN source_country = 'Croatia, Serbia, Bulgaria, Slovenia, Bosnia and Herzegovina' THEN 'ADBA'
            WHEN source_country = 'Czech Republic, Hungary, Slovakia' THEN 'CZECH'
            WHEN source_country = 'United Kingdom & Ireland' THEN 'UKI'
            ELSE source_country
            END AS country_name,
            i.influencer_audience,
            CASE
                WHEN i.influencer_audience < 10000  THEN '1-Nano'
                WHEN i.influencer_audience >= 10000 and i.influencer_audience < 50000  THEN '2-Micro'
                WHEN i.influencer_audience >= 50000 and i.influencer_audience < 250000  THEN '3-Mid'
                WHEN i.influencer_audience >= 250000 and i.influencer_audience < 1000000  THEN '4-Macro'
                WHEN i.influencer_audience >= 1000000 and i.influencer_audience < 5000000  THEN '5-Top'
                ELSE '6-VIP'
                END AS tiers,
        FROM `itg-btdppublished-gbl-ww-pd.btdp_ds_c2_802_consumertouchpointsperformance_eu_pd.influence_campaigns_efficiency_v4`,
            UNNEST(influencers) AS i,
            UNNEST(i.platforms) AS p,
            UNNEST(p.published_posts) AS ppo,
            UNNEST([p]) AS po
        WHERE
            zone = 'Europe'
            AND LOWER(p.platform) IN ('instagram', 'tiktok', 'youtube')
            AND campaign_type IN ('Content Creation')
            AND p.content_fees_eur > 0
            AND p.posts_contracted > 0
            AND ppo.post_id IS NOT NULL
            AND ppo.post_date BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 36 MONTH) AND CURRENT_DATE()
            AND i.influencer_id IN (
            SELECT DISTINCT i_sub.influencer_id
            FROM `itg-btdppublished-gbl-ww-pd.btdp_ds_c2_802_consumertouchpointsperformance_eu_pd.influence_campaigns_efficiency_v4`,
                UNNEST(influencers) AS i_sub,
                UNNEST(i_sub.platforms) AS p_sub,
                UNNEST(p_sub.published_posts) AS ppo_sub
            WHERE ppo_sub.post_date BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 36 MONTH) AND CURRENT_DATE()
            GROUP BY i_sub.influencer_id
            HAVING COUNT(DISTINCT ppo_sub.post_id) <= 90
            )
        ),

        Stories_Raw AS (
        SELECT 
            *,
            COUNT(*) OVER(PARTITION BY channel_id, post_date, CAST(content_fees_eur AS STRING), post_title) AS actual_post_count,
            ROW_NUMBER() OVER(PARTITION BY channel_id, post_date, CAST(content_fees_eur AS STRING), post_title ORDER BY engagements DESC) AS story_row_num
        FROM FilteredPosts
        WHERE LOWER(deliverable_type) = 'story'
        ),

        Stories_Processed AS (
        SELECT 
            * EXCEPT(posts_contracted, story_row_num, actual_post_count),
            CASE 
            WHEN actual_post_count > 1 THEN actual_post_count 
            ELSE posts_contracted 
            END AS posts_contracted,
            SAFE_DIVIDE(content_fees_eur, CASE WHEN actual_post_count > 1 THEN actual_post_count ELSE posts_contracted END) AS post_cost,
            SAFE_DIVIDE(content_fees, CASE WHEN actual_post_count > 1 THEN actual_post_count ELSE posts_contracted END) AS post_cost_oc
        FROM Stories_Raw
        WHERE story_row_num = 1
        ),

        Non_Stories_Processed AS (
        SELECT 
            * EXCEPT(posts_contracted),
            posts_contracted AS posts_contracted,
            SAFE_DIVIDE(content_fees_eur, posts_contracted) AS post_cost,
            SAFE_DIVIDE(content_fees, posts_contracted) AS post_cost_oc
        FROM FilteredPosts
        WHERE LOWER(deliverable_type) != 'story' OR deliverable_type IS NULL
        ),

        Combined_Posts AS (
        SELECT * FROM Stories_Processed
        UNION ALL
        SELECT * FROM Non_Stories_Processed
        ),

        Calculated_Metrics AS (
        SELECT 
            *,
            SAFE_DIVIDE(engagements, potential_reach) AS eng_rate,
            SAFE_DIVIDE(post_cost, engagements) AS CPE,
            SAFE_DIVIDE(post_cost_oc, engagements) AS CPE_oc,
            CASE 
            WHEN LOWER(deliverable_type) = 'story' THEN SAFE_DIVIDE(post_cost, NULLIF(story_views, 0))
            ELSE SAFE_DIVIDE(post_cost, NULLIF(COALESCE(total_video_views, video_views), 0))
            END AS CPV,
            CASE 
            WHEN LOWER(deliverable_type) = 'story' THEN SAFE_DIVIDE(post_cost_oc, NULLIF(story_views, 0))
            ELSE SAFE_DIVIDE(post_cost_oc, NULLIF(COALESCE(total_video_views, video_views), 0))
            END AS CPV_oc
        FROM Combined_Posts
        WHERE potential_reach IS NOT NULL 
            AND potential_reach > 0
        ),

        categ_replacements AS (
            SELECT 'old' AS old_value, 'new' AS new_value
            UNION ALL SELECT 'ALL SKIN', 'Skincare'
            UNION ALL SELECT 'ALL MAKEUP', 'Makeup'
            UNION ALL SELECT 'Face Care Caring', 'Skincare'
            UNION ALL SELECT 'Hair Care', 'Haircare'
            UNION ALL SELECT 'Face Makeup', 'Makeup'
            UNION ALL SELECT 'ALL HAIR', 'Haircare'
            UNION ALL SELECT 'Eye Makeup', 'Makeup'
            UNION ALL SELECT 'Body Care', 'Skincare'
            UNION ALL SELECT 'Sun Care', 'Skincare'
            UNION ALL SELECT 'Lip Makeup', 'Makeup'
            UNION ALL SELECT 'Women Fragrance', 'Fragrance'
            UNION ALL SELECT 'ALL FRAGRANCE', 'Fragrance'
            UNION ALL SELECT 'Hair Color', 'Haircare'
            UNION ALL SELECT 'OTHER', 'MULTI CATEGORY'
            UNION ALL SELECT 'Nail Makeup', 'Makeup'
            UNION ALL SELECT 'Multiple Categories', 'MULTI CATEGORY'
            UNION ALL SELECT 'Men Fragrance', 'Fragrance'
            UNION ALL SELECT 'Face Care Cleansing', 'Skincare'
            UNION ALL SELECT 'Hair Styling', 'Haircare'
            UNION ALL SELECT 'Men Skin Care', 'Skincare'
            UNION ALL SELECT 'Skincare Suncare', 'Skincare'
            UNION ALL SELECT 'SKINCARE', 'Skincare'
            UNION ALL SELECT 'Skin', 'Skincare'
            UNION ALL SELECT 'Skincare Cleansing', 'Skincare'
            UNION ALL SELECT 'MAKEUP', 'Makeup'
            UNION ALL SELECT 'MULTI BRAND', 'MULTI CATEGORY'
        ),

        src_sdds_perf AS (
        SELECT
            p.*,
            COALESCE(r.new_value, 'MULTI CATEGORY') AS categories_clean
        FROM Calculated_Metrics AS p
        LEFT JOIN categ_replacements r ON p.categories = r.old_value
        )

        SELECT 
        country_name AS country,
        tiers AS tier,
        influencer_audience,
        influencer_id,
        influencer_name,
        influenceur_pseudo,
        platform,
        deliverable_type,
        post_id,
        post_date,
        categories_clean AS category,
        posts_contracted,
        post_cost,
        post_cost_oc,
        engagements,
        potential_reach,
        eng_rate,
        CPE,
        CPV,
        COALESCE(story_views, 0) AS story_views,
        COALESCE(total_video_views, video_views, 0) AS video_views
        FROM src_sdds_perf
        ORDER BY influencer_name, post_date
        