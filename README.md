Easy-to-use, customizable auditing for PostgreSQL using triggers

## Installation

Load `audit.sql` into the database where you want to set up auditing. You can do this via psql or any other tool that lets you execute sql on the database.

```bash
psql -h <db-host> -p <db-port> -U <db-user> -d <db> -f audit.sql --single-transaction
```

## Usage

### Enable

Run the following sql to setup audit on a table

```sql

select audit.enable('account');

```

For a table in a different schema name

```sql
select audit.enable('public.account');
```

#### Options

The function `audit.enable` takes the following arguments.

The first optional argument, `audit_rows`, specifies whether to log row-level changes or only statement-level changes. The default value is `true`, which means that row-level changes will be logged.

```sql

select audit.enable('account', false);

```

The second optional argument, `audit_query_text`, specifies whether to log statement-level changes. The default value is `true`, which means that statement-level changes will be logged.

```sql

select audit.enable('account', true, false);

```

The third optional argument, `audit_inserts`, specifies whether to audit insert statements or only updates/deletes/truncates. The default value is `true`, which means that insert statement will be logged.


```sql

select audit.enable('account', true, true, false);

```

The last optional argument, `ignored_cols`, specifies which columns to exclude from audit logs when rows are updated. If only the ignored columns are updated, the update will not be logged.

```sql

select audit.enable('account', true, true, true, '{updated_at,phone_number}');

```

### Disable

Run the following sql to setup audit on a table

```sql

select audit.disable('account');

```

For a table in a different schema name

```sql
select audit.disable('public.account');
```

### Getting data

The `audit.sql` create table called `logs` and view called `tables`:

1. **tables**: This view shows all tables whose auditing is enabled.
  ```sql
    select * from audit.tables
  ```

2. **logs**: Will store all audit records.
  ```sql
    select * from audit.logs
  ```

## Logs Table Reference

Column | Type | Not&nbsp;Null | Description
--- | --- | :---: | ---
`id` | `uuid` | &#x2611;  | Unique identifier for each auditable event
`schema_name` | `TEXT` | &#x2611;  | Database schema audited table for this event is in
`table_name` | `TEXT` | &#x2611;  | Non-schema-qualified table name of table event occured in
`table_oid` | `OID` | &#x2611;  | Table OID. Changes with drop/create.
`transaction_id` | `BIGINT` || Identifier of transaction that made the change. <br />Unique when paired with `transaction_start_at.`
`row_id` | `TEXT` || Primary key ID of the row. Only for `updates/deletes/truncates`
`action` | `TEXT` | &#x2611;  | Action type: <br /> `insert` <br /> `delete` <br /> `update` <br/> `truncate`
`row_data` | `JSONB` | | Record value. Null for statement-level trigger.<br />For INSERT this is the new tuple.<br /> For DELETE and UPDATE it is the old tuple.
`changed_fields` | `JSONB` | | New values of fields changed by UPDATE. Null except for row-level UPDATE events. <br /> Null for INSERT or DELETE.
`session_user_name` | `TEXT` || Login / session user whose statement caused the event
`application_name` | `TEXT` | | The name of the application when this event occurred.
`client_addr` | `INET` | | IP address of client that issued query. Null for unix domain socket.
`client_port` | `INTEGER` | | Port address of client that issued query. <br />Undefined for unix socket.
`client_query` | `TEXT` | | Top-level query that caused this auditable event. <br />May be more than one.
`statement_only` | `BOOLEAN` | &#x2611;  | `t` if audit event is from an FOR EACH STATEMENT trigger <br /> `f` for FOR EACH ROW
`transaction_start_at` | `TIMESTAMP` | &#x2611; | Transaction start timestamp for tx in which audited event occurred
`statement_start_at` | `TIMESTAMP` | &#x2611; | Statement start timestamp for tx in which audited event occurred
`wall_clock_time` | `TIMESTAMP` | &#x2611; | Wall clock time at which audited event's trigger call occurred


## Credits

* [hasura/audit-trigger](https://github.com/hasura/audit-trigger)
* [iloveitaly/audit-trigger](https://github.com/iloveitaly/audit-trigger)
* [2ndQuadrant/audit-trigger](https://github.com/2ndQuadrant/audit-trigger)
* [Wiki Audit Trigger 91plus](https://wiki.postgresql.org/wiki/Audit_trigger_91plus)
