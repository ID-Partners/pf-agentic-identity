# The database

From 0.7.0 (plan item DB-5). How the modules reach PostgreSQL, what bounds each statement, and the driver and
server settings an operator sets so that a slow or unreachable database costs a request its budget and no more.

## Where the connections come from

In production a store's database is a **PingFederate JDBC data store**: the authority's store
(`OIDF_AUTHORITY_DATA_STORE_ID`), the SSF store (`OIDF_SSF_DATA_STORE_ID`) and the agent instance registry's data
source (its "PingFederate data store" field). The modules open no pool of their own; each connection comes from
PingFederate's pool for that data store id, and PingFederate keeps the JDBC URL, the credentials and the pool sizes.
The URL parameters below go in that data store's JDBC URL.

A direct JDBC URL - `OIDF_AUTHORITY_JDBC_URL`, `OIDF_SSF_JDBC_URL`, the instance registry's "JDBC URL" field - is for
development. Each is `forbidden-in-production` in its settings catalogue, and from 0.7.0 the code refuses one under
the production profile as well, naming the component and the data store setting to use instead
(`DataSources.refuseDirectInProduction` in `libs/platform`). A direct URL opens an unpooled connection per use.

Every store is PostgreSQL. A `jdbc:h2:` or `jdbc:hsqldb:` URL is refused when it is read, and a data store whose
database reports itself as H2 or HSQLDB (PingFederate's own bundled HSQLDB among them) is refused at its first
connection: both were dropped in 0.5.0.

## The driver

The image carries PostgreSQL's JDBC driver, PgJDBC, in `server/default/lib` from 0.7.0
([F-0330](../findings.md#f-0330); [build/pingfederate/README.md](../../image/README.md#postgresqls-jdbc-driver)):
`postgresql-42.7.13.jar`, the version the tests run on. A PingFederate JDBC data store on PostgreSQL uses it with the
driver class `org.postgresql.Driver`, and a direct URL in development opens through it too. Before 0.7.0 the image had
none, and the release notes said to add one: remove a copy you added to `server/default/lib` yourself, or keep
exactly one.

An image of your own, built `FROM` the stock PingFederate rather than from this repository's Dockerfile, still has no
driver: add one to `server/default/lib`.

## What bounds a statement

Every query and change the stores make goes through `platform.jdbc.Jdbc` (see `libs/platform/README.md`, "jdbc").
The stores run no DDL: the schema is `oidf-db-migrate.jar`'s (see [database-migrations.md](database-migrations.md)). Each
operation has a deadline - 10 seconds unless its caller gives one - and each statement it makes is given
`Statement.setQueryTimeout` of what is left of that deadline, rounded up to whole seconds. A statement is not made
at all once the deadline has passed. A read, and the agent registry's idempotent upsert, are run again on a
connection failure (SQLState class `08`), a serialisation failure (`40001`) or a deadlock (`40P01`), at most three
times in all and only while the deadline has room; a write inside a transaction is never retried.

The query timeout bounds a statement once the driver is running it. It does not bound opening a connection, a
socket that stops answering, or a statement that outlives the client: those are the driver's and the server's to
bound, with the settings below.

## PgJDBC parameters for the data store's URL

Set these in the PingFederate data store's JDBC URL, for example
`jdbc:postgresql://db.internal:5432/idm?sslmode=verify-full&sslrootcert=/opt/out/instance/server/default/conf/db-ca.pem&connectTimeout=5&socketTimeout=30&loginTimeout=10&tcpKeepAlive=true`.
The values are a starting point; `socketTimeout` must be longer than the longest statement you expect, or the
driver closes a connection under a statement that would have finished.

The text below is quoted from the PgJDBC documentation, "Connection Parameters",
<https://jdbc.postgresql.org/documentation/use/>, read on 2026-10-05:

- **`connectTimeout`** (int, default 10) - "The timeout value used for socket connect operations. If
  connecting to the server takes longer than this value, the connection is broken. The timeout is specified in
  seconds max(2147484) and a value of zero means that it is disabled."
- **`socketTimeout`** (int, default 0) - "The timeout value used for socket read operations. If
  reading from the server takes longer than this value, the connection is closed. This can be used as both a brute
  force global query timeout and a method of detecting network problems. The timeout is specified in seconds
  max(2147484) and a value of zero means that it is disabled." The default leaves a connection whose server has
  gone silent waiting for ever.
- **`loginTimeout`** (int, default 0) - "Specify how long to wait for establishment of a database
  connection. The timeout is specified in seconds max(2147484)."
- **`tcpKeepAlive`** (boolean, default false) - "Enable or disable TCP keep-alive probe." Turn it on,
  so a pooled connection through a firewall or load balancer that dropped it is found dead.
- **`sslmode`** (String, default prefer) - "possible values include disable , allow , prefer , require , verify-ca and verify-full .
  require , allow and prefer all default to a non-validating SSL factory and do not check the validity of the
  certificate or the host name. verify-ca validates the certificate, but does not verify the hostname. verify-full
  will validate that the certificate is correct and verify the host connected to has the same hostname as the
  certificate. Default is prefer". Use `verify-full`: the default, `prefer`, checks neither the certificate nor the
  host.
- **`sslrootcert`** (String, default defaultdir/root.crt) - "File name of the SSL root certificate. It
  can be a PEM encoded X509v3 certificate." Point it at the CA that signed the database server's certificate.

## A statement timeout on the role

Give the role the data store connects as a `statement_timeout` of its own, so a statement is ended by the server
even when no client is left to cancel it:

```sql
ALTER ROLE pf_agentic SET statement_timeout = '30s';
```

From the PostgreSQL 18 documentation, read on 2026-10-05:

- `statement_timeout` (<https://www.postgresql.org/docs/current/runtime-config-client.html>): "Abort any statement
  that takes more than the specified amount of time. [...] If this value is specified without units, it is taken as
  milliseconds. A value of zero (the default) disables the timeout." And: "Setting statement_timeout in
  postgresql.conf is not recommended because it would affect all sessions."
- `ALTER ROLE ... SET` (<https://www.postgresql.org/docs/current/sql-alterrole.html>): "Whenever the role subsequently
  starts a new session, the specified value becomes the session default, overriding whatever setting is present in
  postgresql.conf or has been received from the postgres command line. This only happens at login time".

PgJDBC's `options` parameter can set it per connection instead ("For example setting this to -c
statement_timeout=5min would set the statement timeout parameter for this session to 5 minutes.", the same PgJDBC
page). The role setting is the one that holds for every client of that role.

Keep the role's timeout longer than the modules' own (10 seconds per operation): theirs ends a statement first and
says which operation ran out of time; the role's is the backstop.
