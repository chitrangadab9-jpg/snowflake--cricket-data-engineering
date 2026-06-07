-- ============================================================
-- FILE: stage_external_s3.sql
-- PURPOSE: Connect Snowflake to AWS S3 via Storage Integration + External Stage + Snowpipe
-- Layer: LAND
-- NOTE: This is a second loading path added to the existing project.
--       It feeds the same match_raw_tbl. Nothing downstream changes.
-- ============================================================

-- ---------------------------------------------------------------
-- STEP 1: Create Storage Integration
-- ---------------------------------------------------------------
-- Snowflake never stores your AWS credentials directly.
-- Instead it creates its own IAM identity and assumes your IAM role.
-- This trust relationship is the Storage Integration.

CREATE OR REPLACE STORAGE INTEGRATION cricket_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::447444645041:role/myrole'
    STORAGE_ALLOWED_LOCATIONS = ('s3://snow-bucket123/cricket/');

-- ---------------------------------------------------------------
-- STEP 2: Get Snowflake AWS identity to update IAM trust policy
-- ---------------------------------------------------------------
-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
-- from the output and paste them into the IAM Role Trust Relationship in AWS

DESC INTEGRATION cricket_s3_integration;

-- ---------------------------------------------------------------
-- STEP 3: Create External Stage pointing to S3
-- ---------------------------------------------------------------
-- Unlike internal stage, this does not store files itself.
-- It is just a pointer — tells Snowflake where files live on S3.
-- Key difference from internal stage: has URL + STORAGE_INTEGRATION

CREATE OR REPLACE STAGE cricket.land.my_s3_cricket_stage
    STORAGE_INTEGRATION = cricket_s3_integration
    URL = 's3://snow-bucket123/cricket/'
    FILE_FORMAT = cricket.land.my_json_format;

-- Verify S3 files are visible through the external stage
LIST @cricket.land.my_s3_cricket_stage;

-- ---------------------------------------------------------------
-- STEP 4: Create Snowpipe for auto-ingestion
-- ---------------------------------------------------------------
-- Snowpipe listens for S3 event notifications via SQS.
-- The moment a new file lands on S3, AWS notifies Snowpipe
-- and it loads the file immediately — no schedule needed.
-- Compare: Task checks every 5 min. Snowpipe loads instantly.

CREATE OR REPLACE PIPE cricket.land.cricket_s3_pipe
    AUTO_INGEST = TRUE
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

-- After creating the pipe, get the SQS ARN from notification_channel column.
-- Go to AWS Console → S3 → your-bucket → Properties → Event Notifications
-- → Create → Event type: PUT → Destination: SQS → paste the ARN

use role accountadmin;
SHOW PIPES;

-- Verify pipe is running
SELECT SYSTEM$PIPE_STATUS('cricket.land.cricket_s3_pipe');
