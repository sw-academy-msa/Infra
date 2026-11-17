-- 운영 Command DB에 Product·Order 원본 DB와 계정을 준비합니다. 각 서비스 레포의 docker/postgres/create-*.sql과
-- 같은 구조(DB 소유권은 관리자, 업무 스키마만 앱 소유)를 따릅니다. 비밀번호는 init.sh가 psql 변수로만 넘깁니다.
-- 다시 실행해도 데이터는 바꾸지 않고, 계정 비밀번호만 SSM 값으로 맞춥니다.
\set ON_ERROR_STOP on
SET log_statement = 'none';
SET log_min_error_statement = 'panic';

DO $$
BEGIN
    IF current_database() <> 'postgres' OR current_user <> 'command_admin' THEN
        RAISE EXCEPTION '운영 Command DB 관리자·관리 DB가 아닙니다. 대상 서버를 확인하세요.';
    END IF;
    -- 이미 있는 계정이 과한 권한을 가졌다면 덮어쓰지 않고 멈춥니다.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('product', 'orders', 'metrics')
               AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin)) THEN
        RAISE EXCEPTION '기존 서비스 계정의 권한이 예상과 다릅니다.';
    END IF;
END $$;

-- 계정: 없으면 만들고, 있으면 비밀번호만 SSM 값으로 맞춥니다.
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'product') AS missing \gset
\if :missing
CREATE ROLE product LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
\endif
ALTER ROLE product PASSWORD :'product_password';

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'orders') AS missing \gset
\if :missing
CREATE ROLE orders LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
\endif
ALTER ROLE orders PASSWORD :'orders_password';

-- 모니터링 전용 계정입니다. 업무 데이터는 읽지 못하고 통계 뷰만 읽습니다.
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics') AS missing \gset
\if :missing
CREATE ROLE metrics LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
\endif
ALTER ROLE metrics PASSWORD :'metrics_password';
GRANT pg_monitor TO metrics;

-- DB: CREATE DATABASE는 트랜잭션 밖에서만 됩니다. 실패해도 기존 DB를 지우고 다시 만들지 않습니다.
SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'product_command') AS missing \gset
\if :missing
CREATE DATABASE product_command TEMPLATE template0 ENCODING 'UTF8';
\endif
REVOKE ALL ON DATABASE product_command FROM PUBLIC;
GRANT CONNECT ON DATABASE product_command TO product, metrics;
ALTER ROLE product IN DATABASE product_command SET search_path TO product;

SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'order_command') AS missing \gset
\if :missing
CREATE DATABASE order_command TEMPLATE template0 ENCODING 'UTF8';
\endif
REVOKE ALL ON DATABASE order_command FROM PUBLIC;
GRANT CONNECT ON DATABASE order_command TO orders, metrics;
ALTER ROLE orders IN DATABASE order_command SET search_path TO orders;

-- 업무 스키마는 앱 계정이 소유합니다. Flyway도 이 스키마 안에 이력 테이블을 만듭니다.
\connect product_command
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS product AUTHORIZATION product;
REVOKE ALL ON SCHEMA product FROM PUBLIC;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'product' AND pg_get_userbyid(nspowner) = 'product') THEN
        RAISE EXCEPTION 'product 스키마 소유자가 예상과 다릅니다.';
    END IF;
END $$;

\connect order_command
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS orders AUTHORIZATION orders;
REVOKE ALL ON SCHEMA orders FROM PUBLIC;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'orders' AND pg_get_userbyid(nspowner) = 'orders') THEN
        RAISE EXCEPTION 'orders 스키마 소유자가 예상과 다릅니다.';
    END IF;
END $$;

\echo 'Command DB 준비 완료: product_command(product), order_command(orders), metrics'
