use DBI;

$dbh = DBI->connect("dbi:SQLite:dbname=test.db", "", "");

$dbh->disconnect();
