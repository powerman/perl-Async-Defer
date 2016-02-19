[![Build Status](https://travis-ci.org/powerman/perl-Async-Defer.svg?branch=master)](https://travis-ci.org/powerman/perl-Async-Defer)
[![Coverage Status](https://coveralls.io/repos/powerman/perl-Async-Defer/badge.svg?branch=master)](https://coveralls.io/r/powerman/perl-Async-Defer?branch=master)

# NAME

Async::Defer - VM to write and run async code in usual sync-like way

# VERSION

This document describes Async::Defer version v0.9.5

# SYNOPSIS

    use Async::Defer;

    # ... CREATE

    my $defer  = Async::Defer->new();
    my $defer2 = $defer->clone();

    # ... SETUP

    $defer->do(sub{
        my ($d, @param) = @_;
        # run sync/async code which MUST end with one of:
        # $d->done(@result);
        # $d->throw($error);
        # $d->continue();
        # $d->break();
    });

    $defer->if(sub{ my $d=shift; return 1 });

      $defer->try();

        $defer->do($defer2);

      $defer->catch(
        qr/^io:/    => sub{
            my ($d,$err) = @_;
            # end with $d->done/throw/continue/break
        },
        qr/.*/      => sub{     # WILL CATCH ALL EXCEPTIONS
            my ($d,$err) = @_;
            # end with $d->done/throw/continue/break
        },
        FINALLY     => sub{
            my ($d,$err,@result) = @_;
            # end with $d->done/throw/continue/break
        },
      );

    $defer->else();

      $defer->while(sub{ my $d=shift; return $d->iter() <= 3 });

        $defer->do(sub{
            my ($d) = @_;
            # may access $d->iter() here
            # end with $d->done/throw/continue/break
        });

      $defer->end_while();

    $defer->end_if();

    $defer->{anyvar} = 'anyval';

    # ... START

    $defer->run();

# DESCRIPTION

**WARNING: This is experimental code, public interface may change.**

This module's goal is to simplify writing complex async event-based code,
which usually mean huge amount of callback/errback functions, very hard to
support. It was initially inspired by Python/Twisted's
[Deferred](http://twistedmatrix.com/documents/10.1.0/core/howto/defer.html)
object, but go further and provide virtual machine which allow you to
write/define complete async program (which consists of many
callback/errback) in sync way, just like you write usual non-async
programs.

Main idea is simple. For example, if you've this non-async code:

    $var = fetch_val();
    process_val( $var );

and want to make `fetch_val()` async, you usually do something like this:

    fetch_val( cb => \&value_fetched );
    sub value_fetched {
        my ($var) = @_;
        process_val( $var );
    }

With Async::Defer you will split initial non-async code in sync parts (usually
this mean - split on assignment operator):

    ### 1
           fetch_val();
    ### 2
    $var =
    process_val( $var );

then wrap each part in separate anon sub and add Defer object to join
these parts together:

    $d = Async::Defer->new();
    $d->do(sub{
        my ($d) = @_;
        fetch_val( $d );    # will call $d->done('…result…') when done
    });
    $d->do(sub{
        my ($d, $var) = @_;
        process_val( $var );
        $d->done();         # this sub is sync, it call done() immediately
    });
    $d->run();

These anon subs are similar to _statements_ in perl. Between these
_statements_ you can use _flow control_ operators like `if()`,
`while()` and `try()`/`catch()`. And inside _statements_ you can
control execution flow using `done()`, `throw()`, `continue()`
and `break()` operators when current async function will finish and
will be ready to go to the continue step.
Finally, you can use Async::Defer object to keep your _local variables_ -
this object is empty hash, and you can create any keys in it.
Single Defer object described this way is sort of single _function_.
And it's possible to _call_ another functions by using another Defer
object as parameter for `do()` instead of usual anon sub.

While you can use both sync and async sub in `do()`, they all **MUST**
call one of `done()`, `throw()`, `continue()` or `break()` when they finish
their work, and do this **ONLY ONCE**. This is Defer's way to proceed from
one step to another, and if not done right Defer object's behaviour is
undefined!

## PERSISTENT STATE, LOCAL VARIABLES and SCOPE

There are several ways to implement this, and it's unclear yet which
way is the best. We can implement full-featured stack with local variables
similar to perl's `local` using getter/setter methods; we can fill called
Defer objects with copy of all keys in parent Defer object (so called
object will have full read-only access to parent's scalar data, and read/write
access to parent's reference data types); we can do nothing and let user
manually send all needed data to called Defer object as params and get
data back using returned values (by `done()` or `throw()`).

In current implementation we do nothing, so here is some ways to go:

    ### @results = another_defer(@params)
    $d->do(sub{
        my ($d) = @_;
        my @params_for_another_defer = (…);
        $d->done(@params_for_another_defer);
    });
    $d->do($another_defer);
    $d->do(sub{
        my ($d, @results_from_another_defer) = @_;
        ...
        $d->done();
    });

    ### share some local variables with $another_defer
    $d->do(sub{
        my ($d) = @_;
        $d->{readonly}  = $scalar;
        $d->{readwrite} = $ref_to_something;
        $another_defer->{readonly}  = $d->{readonly};
        $another_defer->{readwrite} = $d->{readwrite};
        $d->done();
    });
    $d->do($another_defer);
    $d->do(sub{
        my ($d) = @_;
        # $d->{readwrite} here may be modifed by $another_defer
        $d->done();
    });

    ### share all variables with $another_defer (run it manually)
    $d->do(sub{
        my ($d) = @_;
        %$another_defer = %$d;
        $another_defer->run($d);
    });
    $d->do(sub{
        my ($d) = @_;
        # all reference-type keys in $d may be modifed by $another_defer
        $d->done();
    });

If you want to reuse same Defer object several times, then you should keep
in mind: keys created inside this object on first run won't be automatically
removed, so on second and continue runs it will see internal data left by
previous runs. This may or may not be desirable behaviour. In later case
you should use `clone()` and run only clones of original object (clones are
created using `%$clone=%$orig`, so they share only reference-type keys
which exists in original Defer):

    $d->do( $another_defer->clone() );
    $d->do( $another_defer->clone() );

## NESTED DEFERS

Async::Defer objects can be nested, and there are two ways to do it.

One way is to add a child defer to the parent defer using `do()` method.

    my $cd = Async::Defer->new();
    
    ## setup the child defer.
    $cd->do( ... );

    ## parent defer
    my $pd = Async::Defer->new();
    $pd->do( ... );
    $pd->do(sub {
        my $d = shift;
        ...;
        $d->done( @arguments_for_child_defer );
    });
    ## run the child defer
    $pd->do($cd);
    $pd->do(sub {
        my ($d, @results_from_child_defer) = @_;
        ...;
    });

The other way is to call `run()` on the child defer with its first
argument being the parent defer. This is very useful when you dynamically
create the child defer in statements of the parent defer.

    ## parent defer
    my $pd = Async::Defer->new();
    $pd->do(sub {
        my ($d, @args) = @_;
    
        ## create the child defer in the statement
        my $cd = Async::Defer->new();
        
        ## setup the child defer
        $cd->do( ... );
    
        ## run() the child.
        ## You do not have to call $d->done explicitly,
        ## because the flow continues from the child to the parent.
        $cd->run($d, @argments_for_child_defer);
    });
    $pd->do(sub {
        my ($d, @results_from_child_defer) = @_;
        ...;
    });

# EXPORTS

Nothing.

# INTERFACE 

- new()

    Create and return Async::Defer object.

- clone()

    Clone existing Async::Defer object and return clone.

    Clone will have same _program_ (_STATEMENTS_ and _OPERATORS_ added to
    original object) and same _local variables_ (non-deep copy of orig object
    keys using `%$clone=%$orig`). After cloning these two objects can be
    modified (by adding new _STATEMENTS_, _OPERATORS_ and modifying variables)
    independently.

    It's possible to `clone()` object which is running right now, cloned object
    will not be in running state - this is safe way to `run()` objects which may
    or may not be already running.

- run( \[ $parent\_defer, @params \] )
- run( \[ \\&callback, @params \] )

    Start executing object's current _program_, which must be defined first by
    adding at least one _STATEMENT_ (`do()` or `<catch(FINALLY=`sub{})>>)
    to this object.

    Usually while `run()` only first _STATEMENT_ will be executed (with optional
    `@params` in parameters). It will just start some async function and
    returns, and `run()` will returns immediately after this too. Actual
    execution of this object will continue when started async function will
    finish (usually after Timer or I/O event) and call this object's `done()`,
    `break()`, `continue()` or `throw()` methods.

    It's possible to make all _STATEMENTS_ sync - in this case full _program_
    will be executed before returning from `run()` - but this has no real sense
    because you don't need Defer object for sync programs.

    If `run()` used to start top-level _program_ (i.e. without `$parent_defer`
    parameter), then there will be no _return value_ at end of _program_ -
    after break _STATEMENT_ in this object will call `done()` nothing else will
    happens and any parameters of that break `done()` call will be ignored.
    If this Defer object was started as part of another _program_ (i.e. it was
    added there using `do()` or just manually executed from some _STATEMENT_ with
    defined `$parent_defer` parameter), then it _return value_ will be delivered
    to continue _STATEMENT_ in `$parent_defer` object (See ["NESTED DEFERS"](#nested-defers)).

    The first argument for `run()` may also be a subroutine reference (`\&callback`).
    In this case, the callback is called after break _STATEMENT_ in this object.
    The arguments for the callback are the results of the break _STATEMENT_.
    Any value returned from `\&callback` will be ignored.

- iter()

    This method available only inside `while()` - both in `while()`'s
    `\&conditional` argument and `while()`'s body _STATEMENTS_. It return
    current iteration number for nearest `while()`, starting from 1.

        # this loop will execute 3 times:
        $d->while(sub{  shift->iter() <= 3  });
            $d->do(sub{
                my ($d) = @_;
                printf "Iteration %d\n", $d->iter();
                $d->done();
            });
        $d->end_while();

## STATEMENTS and OPERATORS

All _STATEMENTS_ methods return the Async::Defer object,
so that you can chain method calls.

- do( \\&sync\_or\_async\_code, … )
- do( $child\_defer, … )

    Add _STATEMENT_ to this object's _program_.

    When this _STATEMENT_ should be executed, `\&sync_or_async_code`
    (or `$child_defer`'s first _STATEMENT_) will be called with these params:

        ( $defer_object, @optional_results_from_previous_STATEMENT )

    `do()` accepts multiple arguments. Those _STATEMENTS_ are added to the object
    in that order, and can be mix of any types - i.e. it's same as call `do()`
    sequentially multiple times providing these arguments one-by-one.

        do(
            \&code,
            $defer,
            [$defer1, $defer2, \&code3],
            {
                task1 => $defer4,
                task2 => \&code5,
            },
            \&more_code,
            …
        );

- do( \[\\&sync\_or\_async\_code, $child\_defer, …\], … )
- do( {task1=>\\&sync\_or\_async\_code, task2=>$child\_defer, …}, … )

    Add one _STATEMENT_ to this object's _program_.

    When this _STATEMENT_ should be executed, all these tasks will be started
    simultaneously (Defer objects using `clone()` and `run()`, code by
    transforming into new Defer object and then also `run()`).
    This _program_ will continue only after all these tasks will be finished
    (either with `done()` or `throw()`).

    It's possible to provide params individually for each of these tasks and
    receive results/error returned by each of these tasks, but actual syntax
    depends on how these tasks was named - by id (ARRAY) or by name (HASH):

        $d->do(sub{
            my ($d) = @_;
            $d->done(
                ['param1 for task1', 'param2 for task1'],
                ['param1 for task2'],
                [undef,              'param2 for task3'],
                # no params for task4,task5,…
            );
        });
        $d->do([ $d_task1, $d_task2, $d_task3, $d_some, $d_some ]);
        $d->do(sub{
            my ($d, @taskresults) = @_;
            my $id = 1;
            if (ref $taskresults[$id-1]) {
                print "task $id results:",  @{ $taskresults[$id-1] };
            } else {
                print "task $id throw error:", $taskresults[$id-1];
            }
        });

        $d->do(sub{
            my ($d) = @_;
            $d->done(
                task1 => ['param1 for task1', 'param2 for task1'],
                task2 => ['param1 for task2'],
                task3 => [undef,              'param2 for task3'],
                # no params for task4,task5,…
            );
        });
        $d->do({
            task1 => $d_task1,
            task2 => $d_task2,
            task3 => $d_task3,
            task4 => $d_some,
            task5 => $d_some,
        });
        $d->do(sub{
            my ($d, %taskresults) = @_;
            if (ref $taskresults{task1}) {
                print "task1 results:",  @{ $taskresults{task1} };
            } else {
                print "task1 throw error:", $taskresults{task1};
            }
        });

- if( \\&conditional )
- else()
- end\_if()

    Add conditional _OPERATOR_ to this object's _program_.

    When this _OPERATOR_ should be executed, `\&conditional` will be called
    with single param:

        ( $defer_object )

    The `\&conditional` **MUST** be sync, and return true/false.

- while( \\&conditional )
- end\_while()

    Add loop _OPERATOR_ to this object's _program_.

    When this _OPERATOR_ should be executed, `\&conditional` will be called with
    single param:

        ( $defer_object )

    The `\&conditional` **MUST** be sync, and return true/false.

- try()
- catch( $regex\_or\_FINALLY => \\&sync\_or\_async\_code, ... )

    Add exception handling to this object's _program_.

    In general, try/catch/finally behaviour is same as in Java (and probably
    many other languages).

    If some _STATEMENTS_ inside try/catch block will `throw()`, the thrown error
    can be intercepted (using matching regexp in `catch()`) and handled in any
    way (blocked - if `catch()` handler call `done()`, `continue()` or `break()` or
    replaced by another exception - if `catch()` handler call `throw()`).
    If exception match more than one regexp, first successfully matched
    regexp's handler will be used. Handler will be executed with params:

        ( $defer_object, $error )

    In addition to exception handlers you can also define FINALLY handler
    (by using string `"FINALLY"` instead of regex). FINALLY handler will be
    called in any case (with/without exception) and may handle this in any way
    just like any other exception handler in `catch()`. FINALLY handler will
    be executed with different params:

        # with exception
        ( $defer_object, $error)
        # without exception
        ( $defer_object, @optional_results_from_previous_STATEMENT )

## FLOW CONTROL in STATEMENTS

Unless you are nesting child defers, one and only one of these methods **MUST** be
called at end of each _STATEMENT_, both sync and async!
In the case of nested defers, see ["NESTED DEFERS"](#nested-defers).

- done( @optional\_result )

    Go to continue _STATEMENT_/_OPERATOR_. If continue is _STATEMENT_, it will receive
    `@optional_result` in it parameters.

- throw( $error )

    Throw exception. Nearest matching `catch()` or FINALLY _STATEMENT_ will be
    executed and receive `$error` in it parameter.

- continue()

    Move to beginning of nearest `while()` (or to first _STATEMENT_ if
    called outside `while()`) and continue with continue iteration (if `while()`'s
    `\&conditional` still returns true).

- break()

    Move to first _STATEMENT_/_OPERATOR_ after nearest `while()` (or finish this
    _program_ if called outside `while()` - returning to parent's Defer object
    if any).

# SUPPORT

## Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at [https://github.com/powerman/perl-Async-Defer/issues](https://github.com/powerman/perl-Async-Defer/issues).
You will be notified automatically of any progress on your issue.

## Source Code

This is open source software. The code repository is available for
public review and contribution under the terms of the license.
Feel free to fork the repository and submit pull requests.

[https://github.com/powerman/perl-Async-Defer](https://github.com/powerman/perl-Async-Defer)

    git clone https://github.com/powerman/perl-Async-Defer.git

## Resources

- MetaCPAN Search

    [https://metacpan.org/search?q=Async-Defer](https://metacpan.org/search?q=Async-Defer)

- CPAN Ratings

    [http://cpanratings.perl.org/dist/Async-Defer](http://cpanratings.perl.org/dist/Async-Defer)

- AnnoCPAN: Annotated CPAN documentation

    [http://annocpan.org/dist/Async-Defer](http://annocpan.org/dist/Async-Defer)

- CPAN Testers Matrix

    [http://matrix.cpantesters.org/?dist=Async-Defer](http://matrix.cpantesters.org/?dist=Async-Defer)

- CPANTS: A CPAN Testing Service (Kwalitee)

    [http://cpants.cpanauthors.org/dist/Async-Defer](http://cpants.cpanauthors.org/dist/Async-Defer)

# AUTHOR

Alex Efros &lt;powerman@cpan.org>

# CONTRIBUTORS

Toshio Ito `toshioito [at] cpan.org`

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2011-2012 by Alex Efros &lt;powerman@cpan.org>.

This is free software, licensed under:

    The MIT (X11) License
