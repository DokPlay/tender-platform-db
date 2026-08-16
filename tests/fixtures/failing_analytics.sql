\set ON_ERROR_STOP on

-- Intentional failure used to prove that the complete installer rolls back.
SELECT 1 / 0 AS intentional_atomic_install_failure;
