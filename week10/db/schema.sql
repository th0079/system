-- =====================================================================
-- DB Tier (Data Tier) : MariaDB 스키마
--   users      : 회원 정보 (비밀번호는 평문이 아니라 해시로 저장)
--   login_logs : 로그인 시도 이력 (성공/실패, 접속 IP)
--
-- 실행: sudo mysql < db/schema.sql   (deploy/setup.sh 가 자동 실행)
-- DB 계정(loginapp)과 권한은 비밀번호를 자동 생성해야 하므로 setup.sh 에서 만든다.
-- 여러 번 실행해도 안전하도록 IF NOT EXISTS 를 사용한다.
-- =====================================================================
CREATE DATABASE IF NOT EXISTS loginapp
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE loginapp;

CREATE TABLE IF NOT EXISTS users (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  username      VARCHAR(20)  NOT NULL COMMENT '로그인 ID (영문/숫자/_ 4~20자)',
  password_hash VARCHAR(255) NOT NULL COMMENT 'werkzeug scrypt 해시',
  name          VARCHAR(30)  NOT NULL COMMENT '화면에 표시할 이름',
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login_at DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_username (username)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS login_logs (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED    NULL     COMMENT '존재하지 않는 ID로 시도하면 NULL',
  username   VARCHAR(50)     NOT NULL COMMENT '사용자가 입력한 ID',
  ip_address VARCHAR(45)     NOT NULL COMMENT '접속 IP (IPv4/IPv6)',
  success    TINYINT(1)      NOT NULL COMMENT '1=성공, 0=실패',
  created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_login_logs_user (user_id, created_at),
  CONSTRAINT fk_login_logs_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE=InnoDB;
