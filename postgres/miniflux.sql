\set ON_ERROR_STOP on
\if :{?password_dir}
\else
\set password_dir /run
\endif
\set miniflux_password_file :password_dir /miniflux-postgres-password
SELECT
    pg_read_file(:'miniflux_password_file') AS miniflux_password \gset

SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_roles
        WHERE
            rolname = 'miniflux') AS create_miniflux_role \gset

\if :create_miniflux_role
CREATE ROLE miniflux WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION PASSWORD :'miniflux_password';

\endif
SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_database
        WHERE
            datname = 'miniflux') AS create_miniflux_database \gset

\if :create_miniflux_database
CREATE DATABASE miniflux OWNER miniflux;

\endif
REVOKE CONNECT ON DATABASE miniflux FROM PUBLIC;

GRANT CONNECT ON DATABASE miniflux TO miniflux;
