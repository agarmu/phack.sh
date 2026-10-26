\set ON_ERROR_STOP on
-- Administration uses the local socket; disable the bootstrap TCP password.
ALTER ROLE postgres PASSWORD NULL;
