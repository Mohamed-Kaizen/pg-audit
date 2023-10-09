-- This is based on iloveitaly/audit-trigger.
-- An audit history is important on most tables. Provide an audit trigger that logs to
-- a dedicated audit table for the major relations.
--
-- This file should be generic and not depend on application roles or structures,
-- as it's being listed here:
--
--    https://wiki.postgresql.org/wiki/Audit_trigger_91plus
--
-- This trigger was originally based on
--   http://wiki.postgresql.org/wiki/Audit_trigger
-- but has been completely rewritten.
-- Audited data. Lots of information is available, it's just a matter of how much
-- you really want to record. See:
--
--   http://www.postgresql.org/docs/9.1/static/functions-info.html
--
-- Remember, every column you add takes up more audit table space and slows audit
-- inserts.
--
-- Every index you add has a big impact too, so avoid adding indexes to the
-- audit table unless you REALLY need them. The json GIN/GIST indexes are
-- particularly expensive.
--
-- It is sometimes worth copying the audit table, or a coarse subset of it that
-- you're interested in, into a temporary table where you CREATE any useful
-- indexes and do your analysis.

-- Create a new schema named 'audit'
CREATE SCHEMA audit;

-- Revoke all privileges on this schema
REVOKE ALL ON SCHEMA audit

-- Add a comment to the 'audit' schema
FROM public;
COMMENT ON SCHEMA audit IS 'Out-of-table audit/history logging tables and trigger functions';

-- Create a new table named 'logs' in the 'audit' schema
CREATE TABLE audit.logs (
    id uuid not null,
    schema_name text not null, -- The name of the schema that the audited table is in
    table_name text not null, -- The name of the audited table
    table_oid oid not null, -- The OID of the audited table
    transaction_id bigint, -- The ID of the transaction that made the change
    row_id text, -- Primary key ID of the row
    action TEXT NOT NULL, -- The type of action: insert, delete, update, truncate
    row_data jsonb, -- For INSERT this is the new tuple. For DELETE and UPDATE it is the old tuple.
    changed_fields jsonb, -- New values of fields changed by UPDATE. Null except for row-level UPDATE events.
    session_user_name text, -- The name of the user who executed the statement that caused the event
    application_name text, -- The name of the application when this event occurred
    client_addr inet, -- The IP address of the client that issued the query
    client_port integer, -- The port number of the client that issued the query
    client_query text, -- The top-level query that caused this event
    statement_only boolean not null, -- 't' if audit event is from an FOR EACH STATEMENT trigger, 'f' for FOR EACH ROW
    transaction_start_at TIMESTAMP WITH TIME ZONE NOT NULL, -- The timestamp of the start of the transaction that caused the event
    statement_start_at TIMESTAMP WITH TIME ZONE NOT NULL, -- The timestamp of the start of the statement that caused the event
    wall_clock_time TIMESTAMP WITH TIME ZONE NOT NULL, -- The wall clock time when the event's trigger was called
    PRIMARY KEY (id)
);

-- Revoke all privileges
REVOKE ALL ON audit.logs

-- Add comments
FROM public;
COMMENT ON TABLE audit.logs IS 'History of auditable actions on audited tables, from audit.if_modified_func()';
COMMENT ON COLUMN audit.logs.id IS 'Unique identifier for each auditable event';
COMMENT ON COLUMN audit.logs.schema_name IS 'Database schema audited table for this event is in';
COMMENT ON COLUMN audit.logs.table_name IS 'Non-schema-qualified table name of table event occured in';
COMMENT ON COLUMN audit.logs.table_oid IS 'Table OID. Changes with drop/create. Get with ''tablename''::regclass';
COMMENT ON COLUMN audit.logs.session_user_name IS 'Login / session user whose statement caused the audited event';
COMMENT ON COLUMN audit.logs.transaction_start_at IS 'Transaction start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.logs.statement_start_at IS 'Statement start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.logs.wall_clock_time IS 'Wall clock time at which audited event''s trigger call occurred';
COMMENT ON COLUMN audit.logs.transaction_id IS 'Identifier of transaction that made the change. May wrap, but unique paired with transaction_start_at.';
COMMENT ON COLUMN audit.logs.client_addr IS 'IP address of client that issued query. Null for unix domain socket.';
COMMENT ON COLUMN audit.logs.client_port IS 'Remote peer IP port address of client that issued query. Undefined for unix socket.';
COMMENT ON COLUMN audit.logs.client_query IS 'Top-level query that caused this auditable event. May be more than one statement.';
COMMENT ON COLUMN audit.logs.application_name IS 'Application name set when this audit event occurred. Can be changed in-session by client.';
COMMENT ON COLUMN audit.logs.action IS 'Action type; insert, delete, update, truncate';
COMMENT ON COLUMN audit.logs.row_data IS 'Record value. Null for statement-level trigger. For INSERT this is the new tuple. For DELETE and UPDATE it is the old tuple.';
COMMENT ON COLUMN audit.logs.changed_fields IS 'New values of fields changed by UPDATE. Null except for row-level UPDATE events.';
COMMENT ON COLUMN audit.logs.statement_only IS '''t'' if audit event is from an FOR EACH STATEMENT trigger, ''f'' for FOR EACH ROW';
CREATE INDEX logs_table_oid_idx ON audit.logs(table_oid);
CREATE INDEX logs_transaction_start_at_stm_idx ON audit.logs(statement_start_at);
CREATE INDEX logs_action_idx ON audit.logs(action);

-- Create or replace a function named 'if_modified_func' in the 'audit' schema. This function will be used as a trigger function.
CREATE OR REPLACE FUNCTION audit.if_modified_func() RETURNS TRIGGER AS $body$
DECLARE
    -- Declare a variable of type 'audit.logs'
    audit_row audit.logs;
    include_values boolean;
    log_diffs boolean;
    h_old jsonb;
    h_new jsonb;
    -- Initialize an array of text to hold the column names to be excluded
    excluded_cols text [] = ARRAY []::text [];
BEGIN
    -- Check if the trigger is an AFTER trigger. If not, raise an exception.
    IF TG_WHEN <> 'AFTER' THEN RAISE EXCEPTION 'audit.if_modified_func() may only run as an AFTER trigger';
    END IF;

    -- Initialize the 'audit_row' variable with the details of the auditable event
    audit_row = ROW(
        gen_random_uuid(), -- Unique identifier for each auditable event
        TG_TABLE_SCHEMA::text, -- Database schema audited table for this event is in
        TG_TABLE_NAME::text, -- Non-schema-qualified table name of table event occured in
        TG_RELID, -- Table OID. Changes with drop/create. Get with ''table name''::regclass
        txid_current(), -- Identifier of transaction that made the change. May wrap, but unique paired with transaction_start_at.
        COALESCE(OLD.id, NULL), -- pk ID of the row
        TG_OP, -- Action type; insert, delete, update, truncate
        NULL,
        NULL,
        session_user::text, -- Login / session user whose statement caused the audited event
        current_setting('application_name'), -- Application name set when this audit event occurred. Can be changed in-session by client.
        inet_client_addr(), -- IP address of client that issued query. Null for unix domain socket.
        inet_client_port(), -- Remote peer IP port address of client that issued query. Undefined for unix socket.
        current_query(), -- Top-level query that caused this auditable event. May be more than one statement.
        'f', -- 't' if audit event is from an FOR EACH STATEMENT trigger, 'f' for FOR EACH ROW
        current_timestamp, -- Transaction start timestamp for tx in which audited event occurred
        statement_timestamp(), -- Statement start timestamp for tx in which audited event occurred
        clock_timestamp() -- Wall clock time at which audited event's trigger call occurred
    );

-- Check if the first argument passed to the trigger function is distinct from 'false'
IF NOT TG_ARGV [0]::boolean IS DISTINCT FROM 'f'::boolean THEN
    -- If it's not distinct (i.e., it is 'false'), then set the 'client_query' field of the 'audit_row' to NULL
    audit_row.client_query = NULL;
END IF;

-- Check if the second argument passed to the trigger function is not NULL
IF TG_ARGV [1] IS NOT NULL THEN
    -- If it's not NULL, then set the 'excluded_cols' array to the value of this argument
    excluded_cols = TG_ARGV [1]::text [];
END IF;

-- Check if the operation is an UPDATE at the ROW level
IF (TG_OP = 'UPDATE' AND TG_LEVEL = 'ROW') THEN

    -- Convert the old row data to JSON and remove any columns that are in excluded_cols
    audit_row.row_data = row_to_json(OLD)::JSONB - excluded_cols;

    -- Remove unused variables from audit_row.row_data
    audit_row.row_data = (
        SELECT jsonb_object_agg(key, value)
        FROM jsonb_each(audit_row.row_data)
        WHERE key IN (SELECT column_name FROM information_schema.columns WHERE table_name = TG_TABLE_NAME)
    );

-- Compute the differences between the old and new row data
audit_row.changed_fields = (
    SELECT jsonb_object_agg(tmp_new_row.key, tmp_new_row.value) AS new_data
    FROM jsonb_each_text(row_to_json(NEW)::JSONB) AS tmp_new_row
    JOIN jsonb_each_text(audit_row.row_data) AS tmp_old_row ON (
        tmp_new_row.key = tmp_old_row.key
        AND tmp_new_row.value IS DISTINCT FROM tmp_old_row.value
    )
);

-- Only keep the old values of the fields in audit_row.row_data that were actually updated
audit_row.row_data = (
    SELECT jsonb_object_agg(key, value)
    FROM jsonb_each(audit_row.row_data)
    WHERE key IN (SELECT key FROM jsonb_each_text(audit_row.changed_fields))
);

-- Skip this update if all changed fields are ignored
IF audit_row.changed_fields = '{}'::JSONB THEN
    RETURN NULL;
END IF;

-- Check if the operation is a DELETE at the ROW level
ELSIF (
    TG_OP = 'DELETE'
    AND TG_LEVEL = 'ROW'
) THEN
    -- If it is, then convert the old row data to JSON and remove any columns that are in 'excluded_cols'
    audit_row.row_data = row_to_json(OLD)::JSONB - excluded_cols;

-- Check if the operation is an INSERT at the ROW level
ELSIF (
    TG_OP = 'INSERT'
    AND TG_LEVEL = 'ROW'
) THEN
    -- If it is, then convert the new row data to JSON and remove any columns that are in 'excluded_cols'
    audit_row.row_data = row_to_json(NEW)::JSONB - excluded_cols;

-- Check if the operation is at the STATEMENT level and is one of INSERT, UPDATE, DELETE, or TRUNCATE
ELSIF (
    TG_LEVEL = 'STATEMENT'
    AND TG_OP IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
) THEN
    -- If it is, then set the 'statement_only' field of 'audit_row' to 'true'
    audit_row.statement_only = 't';

-- If none of the above conditions are met, raise an exception
ELSE
    RAISE EXCEPTION '[audit.if_modified_func] - Trigger func added as trigger for unhandled case: %, %',
    TG_OP,
    TG_LEVEL;
    RETURN NULL;
END IF;

-- Insert the audit_row record into the 'logs' table
INSERT INTO audit.logs
VALUES (audit_row.*);

-- Return NULL as this function is a trigger function and does not need to return a value
RETURN NULL;
END;

-- Define the language for the function and set the search_path
$body$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

-- Add a comment to the 'if_modified_func' function

-- Create or replace a function named 'enable' in the 'audit' schema. This function can be used to enable auditing for a specific table.
CREATE OR REPLACE FUNCTION audit.enable(
        target_table regclass, -- The name of the table to be audited
        audit_rows boolean, -- Whether to record each row change or only audit at a statement level
        audit_query_text boolean, -- Whether to record the text of the client query that triggered the audit event
        audit_inserts boolean, -- Whether to audit insert statements or only updates/deletes/truncates
        ignored_cols text [] -- Columns to exclude from update diffs. Updates that change only ignored cols are not inserted into the audit log.
    ) RETURNS void AS $body$
DECLARE
    stm_targets text = 'INSERT OR UPDATE OR DELETE OR TRUNCATE'; -- The operations to be audited
    _q_txt text; -- Variable to hold the CREATE TRIGGER query text
    _ignored_cols_snip text = ''; -- Variable to hold the list of ignored columns in string format

BEGIN
    -- Call the ' audit.disable' function to remove auditing from the target table if it's already enabled

    -- Check if row-level changes should be audited
    IF audit_rows THEN
        -- Check if there are any columns to be ignored
        IF array_length(ignored_cols, 1) > 0 THEN
            _ignored_cols_snip = ', ' || quote_literal(ignored_cols); -- Convert the array of ignored columns to string format
        END IF;

        -- Prepare the CREATE TRIGGER query for row-level auditing
        _q_txt = 'CREATE TRIGGER audit_trigger_row AFTER ' || CASE
            WHEN audit_inserts THEN 'INSERT OR '
            ELSE ''
        END || 'UPDATE OR DELETE ON ' || target_table || ' FOR EACH ROW EXECUTE PROCEDURE audit.if_modified_func(' || quote_literal(audit_query_text) || _ignored_cols_snip || ');';

        RAISE NOTICE '%', _q_txt; -- Print the query for debugging purposes

        EXECUTE _q_txt; -- Execute the query

        stm_targets = 'TRUNCATE'; -- Set stm_targets to 'TRUNCATE' as INSERT, UPDATE, and DELETE operations are already handled by the row-level trigger
    ELSE
    END IF;

    -- Prepare the CREATE TRIGGER query for statement-level auditing
    _q_txt = 'CREATE TRIGGER audit_trigger_stm AFTER ' || stm_targets || ' ON ' || target_table || ' FOR EACH STATEMENT EXECUTE PROCEDURE audit.if_modified_func(' || quote_literal(audit_query_text) || ');';

    RAISE NOTICE '%', _q_txt; -- Print the query for debugging purposes

    EXECUTE _q_txt; -- Execute the query

END;
$body$ language 'plpgsql'; -- Define the language for the function

-- Create or replace a function named 'enable' in the 'audit' schema. This function is an adaptor to an older variant of the 'enable' function without the 'audit_inserts' parameter for backwards compatibility.
CREATE OR REPLACE FUNCTION audit.enable(
        target_table regclass, -- The name of the table to be audited
        audit_rows boolean, -- Whether to record each row change or only audit at a statement level
        audit_query_text boolean, -- Whether to record the text of the client query that triggered the audit event
        ignored_cols text [] -- Columns to exclude from update diffs. Updates that change only ignored cols are not inserted into the audit log.
    ) RETURNS void AS $body$
SELECT audit.enable($1, $2, $3, BOOLEAN 't', ignored_cols); -- Call the 'enable' function with 'audit_inserts' set to 'true'
$body$ LANGUAGE SQL;

-- PostgreSQL doesn't allow variadic calls with 0 params, so provide a wrapper function named 'enable' in the 'audit' schema.
CREATE OR REPLACE FUNCTION audit.enable(
        target_table regclass, -- The name of the table to be audited
        audit_rows boolean, -- Whether to record each row change or only audit at a statement level
        audit_query_text boolean, -- Whether to record the text of the client query that triggered the audit event
        audit_inserts boolean -- Whether to audit insert statements or only updates/deletes/truncates
    ) RETURNS void AS $body$
SELECT audit.enable($1, $2, $3, $4, ARRAY []::text []); -- Call the 'enable' function with an empty array for 'ignored_cols'
$body$ LANGUAGE SQL;

-- Create or replace a function named 'enable' in the 'audit' schema. This function is an older wrapper for backwards compatibility.
CREATE OR REPLACE FUNCTION audit.enable(
        target_table regclass, -- The name of the table to be audited
        audit_rows boolean, -- Whether to record each row change or only audit at a statement level
        audit_query_text boolean -- Whether to record the text of the client query that triggered the audit event
    ) RETURNS void AS $body$
SELECT audit.enable($1, $2, $3, BOOLEAN 't', ARRAY []::text []); -- Call the 'enable' function with 'audit_inserts' set to 'true' and an empty array for 'ignored_cols'
$body$ LANGUAGE SQL;

-- Create or replace a function named 'enable' in the 'audit' schema. This function is a convenience call wrapper for the simplest case of row-level logging with no excluded cols and query logging enabled.
CREATE OR REPLACE FUNCTION audit.enable(target_table regclass) RETURNS void AS $body$
SELECT audit.enable($1, BOOLEAN 't', BOOLEAN 't', BOOLEAN 't'); -- Call the 'enable' function with all boolean parameters set to 'true'
$body$ LANGUAGE 'sql';

-- Add a comment to the 'enable' function
COMMENT ON FUNCTION audit.enable(regclass) IS $body$
Add auditing support to the given table. Row-level changes will be logged with full client query text. No cols are ignored.$body$;

-- Create or replace a function named ' audit.disable' in the 'audit' schema. This function can be used to  audit.disable auditing for a specific table.
CREATE OR REPLACE FUNCTION  audit.disable(target_table regclass) RETURNS void AS $body$
BEGIN
    -- Drop the row-level trigger if it exists on the target table
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_row ON ' || target_table;

    -- Drop the statement-level trigger if it exists on the target table
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_stm ON ' || target_table;
END;
$body$ language 'plpgsql';

-- Add a comment to the ' audit.disable' function
COMMENT ON FUNCTION  audit.disable(regclass) IS $body$ Remove auditing support to the given table.$body$;

-- Create or replace a view named 'tables' in the 'audit' schema. This view lists all tables with auditing enabled.
CREATE OR REPLACE VIEW audit.tables AS
SELECT DISTINCT
    triggers.trigger_schema AS schema, -- The schema of the audited table
    triggers.event_object_table AS name -- The name of the audited table
FROM
    information_schema.triggers -- Use the 'triggers' view in the 'information_schema' catalog
WHERE
    triggers.trigger_name::text IN ('audit_trigger_row'::text, 'audit_trigger_stm'::text) -- Filter for tables that have either of the audit triggers
ORDER BY
    schema, name; -- Order by schema name and then table name

-- Add a comment to the 'tables' view
COMMENT ON VIEW audit.tables IS $body$ View showing all tables with auditing set up. Ordered by schema, then table.$body$;
