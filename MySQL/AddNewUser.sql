Drop User IF EXISTS 'eliang'@'%';

CREATE USER IF NOT EXISTS 'eliang'@'%' IDENTIFIED BY 'A6bA*xucW^jjP0JJ';

CREATE ROLE IF NOT EXISTS 'readonly_vod';

GRANT SELECT, SHOW VIEW ON *.* TO 'readonly_vod';

GRANT 'readonly_vod' TO 'eliang'@'%';

SET DEFAULT ROLE 'readonly_vod' TO 'eliang'@'%';

SELECT * FROM mysql.user
where user like 'e%'
ORDER BY User;


SELECT User, Host FROM mysql.user WHERE account_locked = 'Y' AND password_expired = 'Y';


SELECT VERSION();
SELECT * FROM information_schema.role_edges WHERE TO_USER = 'eliang';

SELECT @@hostname;


SHOW GRANTS FOR 'eliang'@'%';