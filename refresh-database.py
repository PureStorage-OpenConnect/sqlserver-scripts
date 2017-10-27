import purestorage
import pyodbc
import requests
import sh

requests.packages.urllib3.disable_warnings()

db = pyodbc.connect('DRIVER={ODBC Driver 13 for SQL Server};SERVER=tcp:testinstance.puresql.lab;DATABASE=master;UID=demo;PWD=demo',  autocommit = True)
cursor = db.cursor()

cursor.execute('ALTER DATABASE TestDB SET OFFLINE WITH ROLLBACK IMMEDIATE')

sh.umount('/var/opt/mssql/data/TestDB')

array = purestorage.FlashArray("flasharray-m20.puresql.lab", api_token = "28a21f21-7d42-255a-11fd-cf42117ab86d")

array.copy_volume("production-data-volume", "test-data-volume", **{"overwrite": True})

sh.mount('/var/opt/mssql/data/TestDB')

cursor.execute('ALTER DATABASE TestDB SET ONLINE')

array.invalidate_cookie()
