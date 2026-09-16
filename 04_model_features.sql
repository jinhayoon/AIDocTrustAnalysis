-- =====================================================================
-- 04_model_features.sql
--
-- The single table the notebook and the API both read.
-- One row per participant. Nothing downstream reshapes or recomputes.
--
-- THE MOST IMPORTANT THING IN THIS REPO IS THE COMMENT BLOCK BELOW.
-- =====================================================================
--
-- THE TARGET
--
-- target_likelihood_accept comes from LIKELIHOOD_ACCEPT: a 0-100 slider
-- completed on the questionnaire after the headset came off. It is the
-- outcome the study was designed around and the only outcome used here.
--
-- The client-side `treatment_accepted` field is NOT an alternative target
-- and is not stored anywhere in this schema. Two independent reasons:
--
--   1. ZERO VARIANCE. The VR scene had no autonomous terminal state — the
--      researcher stopped it by hand every time — so the client never
--      reached the branch that would write TRUE. The field is FALSE for
--      every participant. It records how sessions were shut down, not what
--      anyone decided. A constant column is not a weak feature, it is an
--      empty one.
--
--   2. CONSTRUCT VALIDITY. Even a correctly-wired version would measure
--      whether a participant verbally declined, out loud, to a system that
--      had just spent ten minutes being helpful, with a researcher in the
--      room. That setting rewards acquiescence. A privately-completed
--      slider is a substantially better measurement of the same construct.
--
-- Nothing is reconstructed from participant speech to stand in for it. The
-- questionnaire item already measures the thing, better.
--
-- =====================================================================
--
-- WHY MOST OF THE QUESTIONNAIRE IS DELIBERATELY ABSENT
--
-- The obvious model — predict trust from perceived professionalism,
-- explanation satisfaction and confidence in decision — reaches R^2 ~ .63
-- and is worthless as a prediction task. Those scales were completed in
-- the same sitting, minutes apart, on the same response format, by the
-- same person, about the same ten minutes of experience. Predicting one
-- from the others measures shared method variance. In ML vocabulary it is
-- target leakage: the "features" are not available before the outcome
-- exists, because they do not exist before the outcome exists.
--
-- So the feature set is restricted to variables genuinely ANTECEDENT to
-- the outcome:
--
--   BLOCK A  Experimental condition        — assigned before the session
--   BLOCK B  Dispositional / demographic   — measured before the headset
--                                            went on
--   BLOCK C  Observed interaction behaviour— derived from the transcript,
--                                            i.e. from the event itself
--                                            rather than from a later
--                                            self-report about it
--
-- Excluded on leakage grounds, listed so the decision is on the record:
-- trust_jian, trust_ability, trust_benevolence, trust_integrity,
-- sds_cognitive, sds_affective, xai_eval, risk_comms, confidence_decision,
-- professionalism, anthropomorphism, intelligence, panas_*, embodiment,
-- mps_*.
--
-- Expect a modest R^2. That is the honest result for behavioural
-- prediction from pre-interaction and in-interaction signal, and it is the
-- number worth defending.
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_model_features;

CREATE MATERIALIZED VIEW mv_model_features AS
SELECT
    p.participant_id,
    c.condition_name,
    c.linguistic_style,
    c.is_interactive,

    -- ---------- TARGET ----------
    ss.likelihood_accept AS target_likelihood_accept,
    -- Secondary target, for a sensitivity check only. The served model
    -- predicts the primary. If the two disagree sharply, that is a finding
    -- about your constructs, not a reason to switch targets mid-project.
    ss.trust_jian        AS target_trust_secondary,

    -- ---------- BLOCK B: dispositional (pre-VR) ----------
    p.age,
    p.gender_code,
    p.education_code,
    p.eczema_experience,
    ss.trust_propensity,
    ss.gaais,
    ss.general_trust_gp,
    ss.mails AS ai_literacy,

    -- ---------- BLOCK C: observed interaction ----------
    -- NULL for every Control participant, by design: they had no dialogue.
    -- We do not impute these. See the README section on the two-model split.
    --
    -- Six features, each measuring something different:
    --   how much back-and-forth   -> n_turn_switches
    --   who took initiative       -> user_question_rate
    --   who did the talking       -> user_to_assistant_word_ratio
    --   one-word compliance / ASR -> minimal_turn_rate
    --   thinking time             -> mean_user_latency_s
    --   how long it ran           -> transcript_span_s
    --
    -- Raw counts (n_user_messages, user_words, assistant_words) stay in
    -- v_transcript_features for sanity-checking but are deliberately NOT
    -- selected here: they are the ingredients of the ratios above and
    -- including both would feed the model the same information twice.
    tf.n_turn_switches,
    tf.user_question_rate,
    tf.user_to_assistant_word_ratio,
    tf.minimal_turn_rate,
    tf.mean_user_latency_s,
    tf.transcript_span_s,

    -- Content flags. train.py drops any that are near-constant.
    tf.mentioned_side_effects,
    tf.performed_allergy_check,
    tf.gave_rule_out_reasoning,
    tf.offered_alternatives,

    -- ---------- audit columns ----------
    (tf.session_id IS NOT NULL) AS has_transcript,
    sc.completeness             AS target_completeness
FROM v_analysis_sample p
JOIN conditions c                  ON c.condition_code = p.condition_code
LEFT JOIN v_scale_scores_wide ss   ON ss.participant_id = p.participant_id
LEFT JOIN v_transcript_features tf ON tf.participant_id = p.participant_id
LEFT JOIN v_scale_scores sc        ON sc.participant_id = p.participant_id
                                  AND sc.scale_name = 'likelihood_accept'
WHERE ss.likelihood_accept IS NOT NULL;   -- no target, no training row

CREATE UNIQUE INDEX idx_mv_model_features_pid
    ON mv_model_features(participant_id);
-- A UNIQUE index is required if you ever want REFRESH MATERIALIZED VIEW
-- CONCURRENTLY, which refreshes without locking readers. Worth knowing.

-- Refresh after any data load:
--   REFRESH MATERIALIZED VIEW mv_model_features;


-- =====================================================================
-- Sanity queries. Run these every time you reload. Cheap, and they catch
-- the class of bug that silently ruins a model.
-- =====================================================================

-- 1. Sample sizes by condition and transcript availability
--    SELECT condition_name, has_transcript, COUNT(*),
--           ROUND(AVG(target_likelihood_accept),1) AS mean_target
--    FROM mv_model_features GROUP BY 1,2 ORDER BY 1,2;

-- 2. Any Control participant with a transcript, or any LLM participant
--    without one? Both indicate a join or labelling error.
--    SELECT * FROM mv_model_features WHERE is_interactive <> has_transcript;

-- 3. Target distribution. Confirm it is not degenerate before modelling.
--    SELECT MIN(target_likelihood_accept), MAX(target_likelihood_accept),
--           ROUND(AVG(target_likelihood_accept),2),
--           ROUND(STDDEV_SAMP(target_likelihood_accept),2), COUNT(*)
--    FROM mv_model_features;

-- 4. Index actually being used?
--    EXPLAIN ANALYZE SELECT * FROM utterances
--    WHERE to_tsvector('english', content) @@ plainto_tsquery('english','side effects');
--    Look for "Bitmap Index Scan on idx_utt_fts" rather than "Seq Scan".
--    Screenshot this for the README — it proves you understand what an
--    index is for.