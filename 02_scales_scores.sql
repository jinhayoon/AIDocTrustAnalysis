-- data cleaning
-- 1. JOIN each raw response to its item metadata
-- 2. Apply reverse-scoring arithmetically, driven by a bool column
-- 3. GROUP BY (participant, scale) and aggregate

-- ------------------------------------------
-- reverse scoring formula : scored = (scale_pts + 1) - raw
-- 	on a 1 - 7 scale: 8 - raw
--
-- this table will become a long shape : one row per per person per question
-- 01_seed_metadata.sql filled a small table called scale_items
-- 	one row per question, e.g.,
-- col names : item_code, scale_name (text), is_reverse_scored (bool), scale_points, aggregation
-- row 1	 : TRUST_GP1, general_trust_gp, true, 7, mean
-- row 2	 : TRUST_GP2, general_trust_gp, false, 7, mean
-- ------------------------------------------

CREATE OR REPLACE VIEW v_scored_responses AS
SELECT
	r.participant_id,
	si.scale_name,
	r.item_code,
	r.raw_value,
	si.is_reverse_scored,
	CASE
		WHEN r.raw_value IS NULL		THEN NULL -- if answer is blank, leave it blank
		WHEN si.is_reverse_scored		THEN (si.scale_points + 1) - r.raw_value -- otherwise, if rulebook says this question is reverse-worded, flip
		ELSE r.raw_value							-- otherwise, use it as is
	END AS scored_value, -- name resulting col as scored_value
	si.aggregation
FROM item_responses r
JOIN scale_items si ON si.item_code = r.item_code; 
-- JOIN glues two tables together side by side, mathcing rows
-- 		ON si.item_code = r.item_code is the matching rule : 
-- 		stick a row from scale_items next to a row from item_responses whenever the item codes are the same



-- ------------------------------------------
-- aggregate to one score per ppt per scale
--
-- GROUP BY participant_id, scale_name : put rows into piles, one pile per combination, then give me one row per pile.
-- 157 ppts x 23 scales = 3600 rows
-- ------------------------------------------
CREATE OR REPLACE VIEW v_scale_scores AS -- remember this question and call it v_scale_Scores
WITH agg AS ( -- CTE : a temporary named result — a scratchpad. It calculates something, calls it agg, and the query below can use it. It exists only while this one query runs.
	SELECT
		participant_id,
		scale_name,
		aggregation,
		COUNT(*)				AS n_items, -- count rows in this pile (e.g., for trust is 11 rows)
		COUNT(scored_value)		AS n_answered, -- count how many of those rows have an actual value
		AVG(scored_value)		AS mean_score,
		SUM(scored_value)		AS sum_score
	FROM v_scored_responses
	GROUP BY participant_id, scale_name, aggregation
)
SELECT
	participant_id,
	scale_name,
	n_items,
	n_answered,
	ROUND(n_answered::NUMERIC / n_items, 3) AS completeness,
	-- completeness is the fraction answered (e.g,. if only 14 out of 16 were answered, 14 / 16 = .875)
	-- force decimal division, 3 decimal places
	CASE
		 -- summed scales: all questions answered, use total
        WHEN aggregation = 'sum'  AND n_answered = n_items THEN sum_score
        WHEN aggregation = 'sum'                            THEN NULL
        -- averaged scales: tolerate up to 70% answered
        WHEN aggregation = 'mean' AND n_answered::NUMERIC / n_items >= 0.7 THEN mean_score
        ELSE NULL
    END AS score
FROM agg;


-- ------------------------------------------
-- wide view 
-- ------------------------------------------

CREATE OR REPLACE VIEW v_scale_scores_wide AS
SELECT
    participant_id,
    MAX(score) FILTER (WHERE scale_name = 'trust_propensity')    AS trust_propensity,
    MAX(score) FILTER (WHERE scale_name = 'gaais')               AS gaais,
    MAX(score) FILTER (WHERE scale_name = 'general_trust_gp')    AS general_trust_gp,
    MAX(score) FILTER (WHERE scale_name = 'mails')               AS mails,
    MAX(score) FILTER (WHERE scale_name = 'likelihood_accept')   AS likelihood_accept,
    MAX(score) FILTER (WHERE scale_name = 'xai_eval')            AS xai_eval,
    MAX(score) FILTER (WHERE scale_name = 'trust_jian')          AS trust_jian,
    MAX(score) FILTER (WHERE scale_name = 'trust_ability')       AS trust_ability,
    MAX(score) FILTER (WHERE scale_name = 'trust_benevolence')   AS trust_benevolence,
    MAX(score) FILTER (WHERE scale_name = 'trust_integrity')     AS trust_integrity,
    MAX(score) FILTER (WHERE scale_name = 'sds_cognitive')       AS sds_cognitive,
    MAX(score) FILTER (WHERE scale_name = 'sds_affective')       AS sds_affective,
    MAX(score) FILTER (WHERE scale_name = 'panas_positive')      AS panas_positive,
    MAX(score) FILTER (WHERE scale_name = 'panas_negative')      AS panas_negative,
    MAX(score) FILTER (WHERE scale_name = 'embodiment')          AS embodiment,
    MAX(score) FILTER (WHERE scale_name = 'mps_physical')        AS mps_physical,
    MAX(score) FILTER (WHERE scale_name = 'mps_social')          AS mps_social,
    MAX(score) FILTER (WHERE scale_name = 'mps_self')            AS mps_self,
    MAX(score) FILTER (WHERE scale_name = 'risk_comms')          AS risk_comms,
    MAX(score) FILTER (WHERE scale_name = 'confidence_decision') AS confidence_decision,
    MAX(score) FILTER (WHERE scale_name = 'professionalism')     AS professionalism,
    MAX(score) FILTER (WHERE scale_name = 'anthropomorphism')    AS anthropomorphism,
    MAX(score) FILTER (WHERE scale_name = 'intelligence')        AS intelligence
FROM v_scale_scores
GROUP BY participant_id;
 


-- ------------------------------------------
-- 
CREATE OR REPLACE VIEW v_analysis_sample AS
SELECT p.*
FROM participants p
LEFT JOIN response_exclusions e ON e.participant_id = p.participant_id
WHERE e.participant_id IS NULL;








