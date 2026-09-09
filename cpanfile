requires 'perl', '5.020';

requires 'DBI';
requires 'DBD::SQLite';

on 'test' => sub {
    requires 'Test::More', '0.96';
    requires 'Test::Exception';
};
