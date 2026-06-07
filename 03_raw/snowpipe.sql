-- ============================================================
-- FILE: snowpipe.sql
-- PURPOSE: Auto-ingest JSON files from AWS S3 the moment they arrive
-- Layer: RAW
--
-- This is the S3 loading path. It feeds the SAME match_raw_tbl as the
-- internal stage task. Both paths coexist — nothing downstream changes.
-- This was added to demonstrate Snowpipe + S3 integration skills
-- without modifying the existing pipeline.
-- ============================================================

-- ---------------------------------------------------------------
-- How Snowpipe works vs the Task approach:
-- ---------------------------------------------------------------
-- Task approach:   checks stage every 5 minutes → loads if new files found
-- Snowpipe:        AWS notifies Snowpipe the MOMENT a file lands on S3
--                  → Snowpipe loads it immediately (no waiting)
--
-- AUTO_INGEST = TRUE means Snowpipe listens to an SQS queue.
-- AWS sends a message to that queue every time a new file is uploaded to S3.
-- Snowpipe picks up that message and triggers the COPY INTO automatically.

CREATE OR REPLACE PIPE cricket.land.cricket_s3_pipe
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingests cricket JSON files from S3 into match_raw_tbl the moment they arrive'
AS
COPY INTO cricket.raw.match_raw_tbl (
    meta,
    info,
    innings,
    stg_file_name,
    stg_file_row_number,
    stg_file_hashkey,
    stg_modified_ts
)
FROM (
    SELECT
        t.$1:meta::variant,
        t.$1:info::variant,
        t.$1:innings::array,
        metadata$filename,
        metadata$file_row_number,
        metadata$file_content_key,
        metadata$file_last_modified
    FROM @cricket.land.my_s3_cricket_stage t
)
FILE_FORMAT = (FORMAT_NAME = 'cricket.land.my_json_format');

-- ---------------------------------------------------------------
-- After creating the pipe, complete the AWS S3 event notification setup:
-- ---------------------------------------------------------------
-- 1. Run SHOW PIPES to get the SQS notification channel ARN
-- 2. Copy the value from the notification_channel column
-- 3. Go to AWS Console → S3 → your-bucket → Properties → Event Notifications
-- 4. Create notification → Event type: s3:ObjectCreated:*
-- 5. Destination: SQS Queue → paste the ARN from step 2
-- Now S3 will notify Snowpipe every time a new JSON file is uploaded.

SHOW PIPES IN SCHEMA cricket.land;

-- Confirm the pipe is running after setup
SELECT SYSTEM$PIPE_STATUS('cricket.land.cricket_s3_pipe');
