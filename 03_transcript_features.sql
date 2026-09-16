

-- Turns dialogue into numbers. Two views:
--   1. v_utterance_enriched   — adds context to each sentence
--   2. v_transcript_features  — one row per session
--
-- session_id | n_messages | n_user_questions | mean_user_latency_s | ...
-- S054       | 25         | 0                | 8.4                 |
--
-- =====================================================================


-- =====================================================================
-- VIEW 1 — add context to each sentence. Still one row per sentence.
-- =====================================================================
CREATE OR REPLACE VIEW v_utterance_enriched AS
SELECT
    session_id,
    seq,
    speaker,
    content,
    spoken_at,

    -- Seconds since the previous turn. LAG reads the row before.
    -- NULL on the first row of a session, which is correct: there was no
    -- previous turn to respond to.
    EXTRACT(EPOCH FROM (spoken_at - LAG(spoken_at) OVER w))
        AS seconds_since_prev,

    -- Did the speaker change? Consecutive same-speaker rows are common:
    -- the AI sometimes sends two messages in a row, and the speech
    -- recogniser can split one spoken sentence into two rows. So turns
    -- must be counted, never assumed to alternate.
    -- COALESCE makes the first row FALSE explicitly. Without it the first
    -- message of every session counts as a switch and every total is one
    -- too high.
    COALESCE(speaker <> LAG(speaker) OVER w, FALSE)
        AS is_speaker_switch,

    -- Word count. '\S+' means "a run of non-space characters", so this
    -- reads as "count the words".
    regexp_count(content, '\S+') AS word_count,

    -- One question flag, not two. A question mark catches written
    -- questions; the opening-word pattern catches spoken ones the speech
    -- recogniser failed to punctuate. They were only ever used together.
    -- ~* means "matches this pattern, ignoring capitals".
    content LIKE '%?%'
      OR content ~* '^(what|why|how|when|where|which|who|can|could|will|would|do|does|did|is|are|should)\M'
        AS is_question

FROM utterances
WINDOW w AS (PARTITION BY session_id ORDER BY seq);


-- =====================================================================
-- VIEW 2 — one row per session.
--
-- Six behavioural features, each measuring something different. 
-- =====================================================================
CREATE OR REPLACE VIEW v_transcript_features AS
WITH agg AS (
    SELECT
        session_id,

        -- Raw counts. Kept because the ratios below are built from them,
        -- and because they make sanity-checking possible.
        COUNT(*) FILTER (WHERE speaker = 'user')             AS n_user_messages,
        COUNT(*) FILTER (WHERE is_speaker_switch)            AS n_turn_switches,
        SUM(word_count) FILTER (WHERE speaker = 'user')      AS user_words,
        SUM(word_count) FILTER (WHERE speaker = 'assistant') AS assistant_words,
        COUNT(*) FILTER (WHERE speaker = 'user' AND is_question)
                                                             AS n_user_questions,
        COUNT(*) FILTER (WHERE speaker = 'user' AND word_count <= 2)
                                                             AS n_minimal_user_turns,

        -- Pacing
        AVG(seconds_since_prev) FILTER (WHERE speaker = 'user' AND is_speaker_switch)
                                                             AS mean_user_latency_s,
        EXTRACT(EPOCH FROM (MAX(spoken_at) - MIN(spoken_at))) AS transcript_span_s,

        -- Clinical content flags. Each operationalises a theme from the
        -- qualitative analysis of this study, where participants judged
        -- the consultation on whether risks were disclosed, alternatives
        -- offered, and differentials ruled out.
        -- Check their variance before trusting them: a flag that is true
        -- in 98% of sessions carries no information. train.py prints the
        -- proportions and drops near-constant ones.
        BOOL_OR(content ~* 'side.?effect') FILTER (WHERE speaker = 'assistant')
            AS mentioned_side_effects,
        BOOL_OR(content ~* 'allerg') FILTER (WHERE speaker = 'assistant')
            AS performed_allergy_check,
        BOOL_OR(content ~* 'ruled out|differential|considered') FILTER (WHERE speaker = 'assistant')
            AS gave_rule_out_reasoning,
        BOOL_OR(content ~* 'alternative') FILTER (WHERE speaker = 'assistant')
            AS offered_alternatives

    FROM v_utterance_enriched
    GROUP BY session_id
)
SELECT
    a.*,
    s.participant_id,
    s.condition_code,

    -- Ratios, not raw counts. -- compare consultations of different lengths
    a.user_words::NUMERIC           / NULLIF(a.assistant_words, 0)  AS user_to_assistant_word_ratio,
    a.n_user_questions::NUMERIC     / NULLIF(a.n_user_messages, 0)  AS user_question_rate,
    a.n_minimal_user_turns::NUMERIC / NULLIF(a.n_user_messages, 0)  AS minimal_turn_rate

FROM agg a
JOIN sessions s USING (session_id);






