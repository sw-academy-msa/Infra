-- 일반 RDS에 서비스 하나의 DB·계정·스키마를 준비합니다. start.sh가 서비스마다 psql 변수(db, role, password)를 넣어 실행합니다.
-- 구조는 각 서비스 레포의 로컬 초기화 SQL과 같습니다: DB 소유권은 마스터 계정, 업무 스키마만 서비스 계정이 소유합니다.
-- 테이블은 만들지 않습니다. 업무 테이블은 각 서비스의 Flyway 마이그레이션이 만듭니다.
-- 다시 실행해도 데이터는 바꾸지 않고, 계정 비밀번호만 SSM 값으로 맞춥니다.
\set ON_ERROR_STOP on
-- RDS 마스터는 슈퍼유저가 아니라 log_statement를 바꿀 수 없습니다. Parameter Group의 log_statement가 기본값(none)이라
-- 비밀번호가 든 ALTER ROLE 문장은 로그에 남지 않습니다. log_statement를 ddl·all로 바꾸지 마세요(modules/rds).

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role'
               AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin)) AS bad_role \gset
\if :bad_role
-- psql의 \quit은 종료 코드를 못 주므로 예외로 멈춥니다(ON_ERROR_STOP → 실패 종료).
DO $$ BEGIN RAISE EXCEPTION '기존 계정의 권한이 예상과 다릅니다. 덮어쓰지 않습니다.'; END $$;
\endif

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') AS missing \gset
\if :missing
CREATE ROLE :"role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
\endif
ALTER ROLE :"role" PASSWORD :'password';
-- PostgreSQL 16부터는 스키마 소유자로 지정하려면 그 역할로 전환할 수 있어야 합니다. 권한 상속은 하지 않습니다.
GRANT :"role" TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;

SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') AS missing \gset
\if :missing
CREATE DATABASE :"db" TEMPLATE template0 ENCODING 'UTF8';
\endif
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"role";
ALTER ROLE :"role" IN DATABASE :"db" SET search_path TO :"role";

\connect :"db"
REVOKE ALL ON SCHEMA public FROM PUBLIC;
-- 새 스키마는 소유자 외에 권한이 없습니다(PUBLIC 권한 없음). 소유자가 서비스 계정이라 마스터가 따로 회수할 것도 없습니다.
CREATE SCHEMA IF NOT EXISTS :"role" AUTHORIZATION :"role";
SELECT pg_get_userbyid(nspowner) = :'role' AS owner_ok FROM pg_namespace WHERE nspname = :'role' \gset
\if :owner_ok
\echo 준비 완료: :db / :role
\else
DO $$ BEGIN RAISE EXCEPTION '스키마 소유자가 예상과 다릅니다.'; END $$;
\endif
