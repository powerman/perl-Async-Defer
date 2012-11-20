use inc::Module::Install;

name     'Async-Defer';
all_from 'lib/Async/Defer.pm';

perl_version    '5.12.0';
requires        'version';
requires        'Scalar::Util';

test_requires   'Test::More';
test_requires   'Test::Exception';
test_requires   'AE';

recommends      'Test::CheckManifest'   => '0.9';
recommends      'Test::Perl::Critic';
recommends      'Test::Pod::Coverage'   => '1.08';
recommends      'Pod::Coverage'         => '0.18';
recommends      'Test::Pod'             => '1.22';

auto_install;

WriteAll;

