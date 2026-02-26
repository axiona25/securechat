-- SecureChat MySQL initialization
CREATE DATABASE IF NOT EXISTS securechat
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- Grant privileges (utente già creato da MYSQL_USER env)
GRANT ALL PRIVILEGES ON securechat.* TO 'securechat_user'@'%';
FLUSH PRIVILEGES;
