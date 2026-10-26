\set ON_ERROR_STOP on
\if :{?password_dir}
\else
\set password_dir /run
\endif
\set cms_password_file :password_dir /cms-postgres-password
\set cms_demo_password_file :password_dir /cms-demo-postgres-password
SELECT
    pg_read_file(:'cms_password_file') AS cms_password,
    pg_read_file(:'cms_demo_password_file') AS cms_demo_password \gset

-- Safe to rerun on an existing volume; existing passwords are not rotated.
SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_roles
        WHERE
            rolname = 'cms') AS create_cms_role \gset

\if :create_cms_role
CREATE ROLE cms WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    PASSWORD :'cms_password';

\endif
SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_roles
        WHERE
            rolname = 'cms_demo') AS create_cms_demo_role \gset

\if :create_cms_demo_role
CREATE ROLE cms_demo WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION PASSWORD :'cms_demo_password';

\endif
SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_database
        WHERE
            datname = 'cms') AS create_cms_database \gset

\if :create_cms_database
CREATE DATABASE cms OWNER cms;

\endif
SELECT
    NOT EXISTS (
        SELECT
        FROM
            pg_database
        WHERE
            datname = 'cms_demo') AS create_cms_demo_database \gset

\if :create_cms_demo_database
CREATE DATABASE cms_demo OWNER cms_demo;

\endif
REVOKE CONNECT ON DATABASE cms FROM PUBLIC;

GRANT CONNECT ON DATABASE cms TO cms;

REVOKE CONNECT ON DATABASE cms_demo FROM PUBLIC;

GRANT CONNECT ON DATABASE cms_demo TO cms_demo;

-- Administration uses the local socket; disable the bootstrap TCP password.
ALTER ROLE postgres PASSWORD NULL;
