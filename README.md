# WAL_Replication
Стенд состаит из 3 узлов: master (192.168.250.182), slave (192.168.250.183), arbiter (192.168.250.181). На master и slave работает PostgreSQL; на arbiter pgpool2 для обеспечения отказоустойчивости.
На **master** и **slave** выполнить:
```
sudo apt install postgresql-9.5
sudo -u postgres createuser ngw_admin -P -e
sudo apt install postgresql-9.5-postgis-2.2
sudo apt install postgresql-9.5-pgpool2
```
На **arbiter** `sudo apt install pgpool2`
## Настройка потоковой репликации
На **master** отредактировать конфигурационный файл */etc/postgresql/9.5/main/postgresql.conf*:
```
listen_addresses = '192.168.250.182'
wal_level = hot_standby
max_wal_senders = 2
wal_keep_segments = 32
#hot_standby = on
```
В файл */etc/postgresql/9.5/main/pg_hba.conf* добавить:
```
host        replication      postgres         192.168.250.0/24       trust
host        all              all              192.168.250.181/32     trust
```
Перезапустить postgres на **master** `sudo service postgresql restart`
Остановить postgres на **slave** `sudo service postgresql stop`
На **slave** отредактировать `/etc/postgresql/9.5/main/postgresql.conf`:
```
listen_addresses = '192.168.250.183'
hot_standby = on
```
В файл */etc/postgresql/9.5/main/pg_hba.conf* добавить:
```
host        replication      postgres         192.168.250.0/24       trust
host        all              all              192.168.250.181/32     trust
```
На **master** и **slave** настроить доступ по *ssh*:
В файле */etc/ssh/sshd_config* поменять
```
PermitRootLogin yes
PasswordAuthentication yes
UseLogin yes
```
После этого, на **master** создать бэкап БД и отправить на **slave**:
```
sudo -u postgres psql -c "SELECT pg_start_backup('stream');"
sudo rsync -v -a /var/lib/postgresql/9.5/main/ 192.168.250.183:/var/lib/postgresql/9.5/main/ --exclude postmaster.pid
sudo -u postgres psql -c "SELECT pg_stop_backup();"
```
На **slave** создать конфигурационный файл репликации */var/lib/postgresql/9.5/main/recovery.conf*:
```
standby_mode = 'on'
primary_conninfo = 'host=192.168.250.182 port=5432 user=postgres'
trigger_file = 'failover'
```
Поменять владельца файла на *postgres* `sudo chown postgres.postgres /var/lib/postgresql/9.5/main/recovery.conf`
Запусить *postgres* на **slave** `sudo service postgresql start`
Протестировать процесс репликации - создать базу данных на **master**, проверить её наличие в **slave**:
![Снимок экрана от 2020-06-03 00-48-41](https://user-images.githubusercontent.com/61119241/83563101-13f61c00-a534-11ea-90c3-8b5a748cb232.png)
![Снимок экрана от 2020-06-03 00-49-13](https://user-images.githubusercontent.com/61119241/83563152-25d7bf00-a534-11ea-8efc-6ef7646fb965.png)
## Настройка узла масштабирования
На **arbiter** изменить файл */etc/pgpool2/pgpool.conf*:
```
listen_addresses = '*'
backend_hostname0 = '192.168.250.182'
backend_port0 = 5432
backend_weight0 = 1
backend_data_directory0 = '/var/lib/postgresql/9.5/main'

backend_hostname1 = '192.168.250.183'
backend_port1 = 5432
backend_weight1 = 1
backend_data_directory1 = '/var/lib/postgresql/9.5/main'

enable_pool_hba = true
sr_check_user = 'postgres'
health_check_user = 'postgres'
memory_cache_enabled = on
memqcache_oiddir = '/var/log/postgresql/oiddir'
```
Изменить конфигурационный файл */etc/pgpool2/pool_hba.conf*:
```
host all     all     192.168.0.0/16  md5
```
Создать файл */etc/pgpool2/pool_passwd*, где указать пароль от созданного пользователя (записать хэш пароля (md5)):
```
pg_md5 <INSERT PASSWORD HERE>

ngw_admin:<ПОЛУЧЕННЫЙ ХЭШ ДОБАВИТЬ ЗДЕСЬ>
```
Поменять права доступа к файлу с паролем:
```
sudo chown root.postgres /etc/pgpool2/pool_passwd
sudo chmod 664  /etc/pgpool2/pool_passwd
```
Перезагрузить *pgpool*: `sudo service pgpool2 restart`

Проверить работоспособность *pgpool* `psql -p 5432 -h 192.168.250.181 -U ngw_admin -d postgres -c "show pool_nodes"`:

![Снимок экрана от 2020-06-03 01-01-45](https://user-images.githubusercontent.com/61119241/83564255-d72b2480-a535-11ea-9f71-5f42e8b7413e.png)

Если статус **slave** != 2, тогда остановить *pgpool*, удалить лог (смотреть в *pgpool.conf* -> logdir), запустить *pgpool*.
## Настройка автоматического failover
Для настройки автоматического переключения ведомого сервера в роль мастера, необходимо настроить соединение ssh без пароля.
Назначить пароль для пользователя *postgres* на **master** и **slave**: `sudo passwd postgres`
На **arbiter** выполнить `sudo -u postgres ssh-keygen` и отправить ключ на **master** и **slave**:
```
sudo su - postgres
ssh-copy-id 192.168.250.182
ssh-copy-id 192.168.250.183
```
В конфигурационном файле */etc/pgpool2/pgpool.conf* добавить:
```
failover_command = '/etc/pgpool2/failover.sh %d %P %H /var/lib/postgres/9.5/main/failover
```
Создать файл для логирования */var/log/pgpool/failover.log*, присвоить владельца *postgres*
Создать скрипт */etc/pgpool2/failover.sh*, который будет выполняться при потери связи с **master**:
```
#! /bin/sh -x
# Execute command by failover.
# special values:  %d = node id
#                  %H = new master node host name
#                  %P = old primary node id
falling_node=$1          # %d
old_primary=$2           # %P
new_primary=$3           # %H
trigger_file=$4

pghome=/usr/lib/postgresql/9.5
log=/var/log/pgpool/failover.log

date >> $log
echo "failed_node_id=$falling_node new_primary=$new_primary" >> $log

if [ $falling_node = $old_primary ]; then
        if [ $UID = 0 ];then
                su postgres
        fi
        exit 0;
        ssh -T postgres@$new_primary touch $trigger_file
fi;
exit 0;
```
Назначить права на исполнение: `chmod 755 /etc/pgpool2/failover.sh`
Протестировать работоспособность автоматического переключения мастера можно следующим образом:
1. Отключить ведущий сервер **master** `sudo service postgresql stop`
2. Выполнить запрос *show pool_nodes;* на узле масштабирования
3. Смотреть логи pgpool на предмет выполнения скрипта
4. Убедиться в том, что ведомый сервер после выполнения скрипта может принимать запросы на запись 

Проверка: `psql -p 5432 -h 192.168.250.181 -U ngw_admin -d postgres -c "show pool_nodes"`
![Снимок экрана от 2020-06-03 01-19-17](https://user-images.githubusercontent.com/61119241/83565690-443fb980-a538-11ea-9d03-194ad9222de3.png)

Проверка возможность записи в бывшего slave:
![Снимок экрана от 2020-06-03 01-20-15](https://user-images.githubusercontent.com/61119241/83565795-6cc7b380-a538-11ea-8ffc-71e83bdcead4.png)

**SUCCESS**
