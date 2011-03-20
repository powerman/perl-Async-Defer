package Async::Defer;

use 5.012;
use warnings;
use strict;
use Carp;

use version; our $VERSION = qv('0.0.1');    # REMINDER: update Changes

# REMINDER: update dependencies in Makefile.PL
use Scalar::Util qw( refaddr );

## no critic (ProhibitBuiltinHomonyms)

use constant NOT_RUNNING=> -1;
use constant OP_CODE    => 1;
use constant OP_DEFER   => 2;
use constant OP_IF      => 3;
use constant OP_ELSE    => 4;
use constant OP_ENDIF   => 5;
use constant OP_WHILE   => 6;
use constant OP_ENDWHILE=> 7;
use constant OP_TRY     => 8;
use constant OP_CATCH   => 9;
use constant OP_FINALLY => 10;
use constant OP_ENDTRY  => 11;

my %SELF;


sub new {
    my ($class) = @_;
    my $this = bless {}, $class;
    $SELF{refaddr $this} = {
        parent  => undef,
        opcode  => [],
        pc      => NOT_RUNNING,
        iter    => [],
        findone => undef,
    };
    return $this;
}

sub DESTROY {
    my ($this) = @_;
    delete $SELF{refaddr $this};
    return;
}

sub clone {
    my ($this) = @_;
    my $self = $SELF{refaddr $this};

    my $clone = __PACKAGE__->new();
    my $clone_self = $SELF{refaddr $clone};

    $clone_self->{opcode} = [ @{ $self->{opcode} } ];
    %{$clone} = %{$this};
    return $clone;
}

sub iter {
    my ($this) = @_;
    my $self = $SELF{refaddr $this};

    if (!@{ $self->{iter} }) {
        croak 'iter() can be used only inside while';
    }

    return $self->{iter}[-1][0];
}

sub _add {
    my ($this, $op, @param) = @_;
    my $self = $SELF{refaddr $this};
    if ($self->{pc} != NOT_RUNNING) {
        croak 'unable to modify while running';
    }
    push @{ $self->{opcode} }, [ $op, @param ];
    return;
}

sub do {
    my ($this, $code_or_defer) = @_;
    my $op
        = ref $code_or_defer eq 'CODE'      ? OP_CODE
        : eval{$code_or_defer->can('run')}  ? OP_DEFER
        : croak 'require CODE or Defer object in first param'
        ;
    return $this->_add($op, $code_or_defer);
}

sub if {
    my ($this, $code) = @_;
    if (!$code || ref $code ne 'CODE') {
        croak 'require CODE in first param';
    }
    return $this->_add(OP_IF, $code);
}

sub else {
    my ($this) = @_;
    return $this->_add(OP_ELSE);
}

sub end_if {
    my ($this) = @_;
    return $this->_add(OP_ENDIF);
}

sub while {
    my ($this, $code) = @_;
    if (!$code || ref $code ne 'CODE') {
        croak 'require CODE in first param';
    }
    return $this->_add(OP_WHILE, $code);
}

sub end_while {
    my ($this) = @_;
    return $this->_add(OP_ENDWHILE);
}

sub try {
    my ($this) = @_;
    return $this->_add(OP_TRY);
}

sub catch {
    my ($this, @param) = @_;
    if (2 > @param) {
        croak 'require at least 2 params';
    } elsif (@param % 2) {
        croak 'require even number of params';
    }

    my ($finally, @catch);
    while (my ($cond, $code) = splice @param, 0, 2) {
        if ($cond eq 'FINALLY') {
            $finally ||= $code;
        } else {
            push @catch, $cond, $code;
        }
    }

    if (@catch) {
        $this->_add(OP_CATCH, @catch);
    }
    if ($finally) {
        $this->_add(OP_FINALLY, $finally);
    }
    return $this->_add(OP_ENDTRY);
}

sub _check_stack {
    my ($self) = @_;
    my @stack;
    my %op_open  = (
        OP_IF()         => 'end_if()',
        OP_WHILE()      => 'end_while()',
        OP_TRY()        => 'catch()',
    );
    my %op_close = (
        OP_ENDIF()      => [ OP_IF,     'end_if()'      ],
        OP_ENDWHILE()   => [ OP_WHILE,  'end_while()'   ],
        OP_ENDTRY()     => [ OP_TRY,    'catch()'       ],
    );
    my $extra = 0;
    for (my $i = 0; $i < @{ $self->{opcode} }; $i++) {
        my ($op) = @{ $self->{opcode}[ $i ] };
        if ($op == OP_CATCH || $op == OP_FINALLY) {
            $extra++;
        }
        if ($op_open{$op}) {
            push @stack, [$op,0];   # second number is counter for seen OP_ELSE
        }
        elsif ($op_close{$op}) {
            my ($close_op, $close_func) = @{ $op_close{$op} };
            if (@stack && $stack[-1][0] == $close_op) {
                pop @stack;
            } else {
                croak 'unexpected '.$close_func.' at operation '.($i+1-$extra);
            }
        }
        elsif ($op == OP_ELSE) {
            if (!(@stack && $stack[-1][0] == OP_IF)) {
                croak 'unexpected else() at operation '.($i+1-$extra);
            }
            elsif ($stack[-1][1]) {
                croak 'unexpected double else() at operation '.($i+1-$extra);
            }
            $stack[-1][1]++;
        }
    }
    if (@stack) {
        croak 'expected '.$op_open{ $stack[-1][0] }.' at end';
    }
    return;
}

sub run {
    my ($this, $d, @result) = @_;
    my $self = $SELF{refaddr $this};

    my %op_exec = map {$_=>1} OP_CODE, OP_DEFER, OP_FINALLY;
    if (!grep {$op_exec{ $_->[0] }} @{ $self->{opcode} }) {
        croak 'no operations to run, use do() first';
    }
    if ($self->{pc} != NOT_RUNNING) {
        croak 'already running';
    }
    _check_stack($self);

    $self->{parent} = $d;
    $this->done(@result);
    return;
}

sub _op {
    my ($self) = @_;
    my ($op, @param) = @{ $self->{opcode}[ $self->{pc} ] };
    return wantarray ? ($op, @param) : $op;
}

sub done {
    my ($this, @result) = @_;
    my $self = $SELF{refaddr $this};

    if ($self->{findone}) {
        my ($method, @param) = @{ $self->{findone} };
        return $this->$method(@param);
    }

    while (++$self->{pc} <= $#{ $self->{opcode} }) {
        my ($opcode, @param) = _op($self);
        given ($opcode) {
            when (OP_CODE) {
                return $param[0]->($this, @result);
            }
            when (OP_DEFER) {
                return $param[0]->run($this, @result);
            }
            when (OP_CATCH) {
                next;
            }
            when (OP_FINALLY) {
                return $param[0]->($this, @result);
            }
            when (OP_ENDTRY) {
                next;
            }
        }
        @result = ();   # this limitation should help user to avoid subtle bugs
        given ($opcode) {
            when (OP_IF) {
                if (!$param[0]->( $this )) {
                    my $stack = 0;
                    while (++$self->{pc} <= $#{ $self->{opcode} }) {
                        my $op = _op($self);
                          $op == OP_ELSE  && !$stack    ? last
                        : $op == OP_ENDIF && !$stack    ? last
                        : $op == OP_IF                  ? $stack++
                        : $op == OP_ENDIF               ? $stack--
                        :                                 next;
                    }
                }
            }
            when (OP_ELSE) {
                my $stack = 0;
                while (++$self->{pc} <= $#{ $self->{opcode} }) {
                    my $op = _op($self);
                      $op == OP_ENDIF && !$stack    ? last
                    : $op == OP_IF                  ? $stack++
                    : $op == OP_ENDIF               ? $stack--
                    :                                 next;
                }
            }
            when (OP_WHILE) {
                if (!@{$self->{iter}} || $self->{iter}[-1][1] != $self->{pc}) {
                    push @{ $self->{iter} }, [ 1, $self->{pc} ];
                }
                if (!$param[0]->( $this )) {
                    return $this->last();
                }
            }
            when (OP_ENDWHILE) {
                return $this->next();
            }
        }
    }

    $self->{pc} = NOT_RUNNING;
    if ($self->{parent}) {
        $self->{parent}->done(@result);
    }
    return;
}

sub _skip_while {
    my ($self) = @_;
    if (_op($self) == OP_ENDWHILE || $self->{pc} == $#{ $self->{opcode} }) {
        return;
    }
    my $stack = 0;
    my $trystack = 0;
    while (++$self->{pc} < $#{ $self->{opcode} }) {
        my $op = _op($self);
        $op == OP_ENDWHILE && !$stack     ? last
        : $op == OP_WHILE                   ? $stack++
        : $op == OP_ENDWHILE                ? $stack--
        : $op == OP_TRY                     ? $trystack++
        : $op == OP_ENDTRY && $trystack     ? $trystack--
        : $op == OP_FINALLY && !$trystack   ? last
        :                                     next;
    }
    return;
}

sub next {
    my ($this) = @_;
    my $self = $SELF{refaddr $this};

    $self->{findone} = undef;

    _skip_while($self);
    my ($op, @param) = _op($self);
    if ($op == OP_FINALLY) {
        $self->{findone} = ['next'];
        return $param[0]->($this);
    }

    my $stack = 0;
    while (--$self->{pc} > 0) {
        $op = _op($self);
          $op == OP_WHILE && !$stack    ? last
        : $op == OP_ENDWHILE            ? $stack++
        : $op == OP_WHILE               ? $stack--
        :                                 next;
    }
    --$self->{pc};
    if (@{ $self->{iter} }) {
        $self->{iter}[-1][0]++;
    }

    $this->done();
    return;
}

sub last { ## no critic (ProhibitAmbiguousNames)
    my ($this) = @_;
    my $self = $SELF{refaddr $this};

    $self->{findone} = undef;

    _skip_while($self);
    my ($op, @param) = _op($self);
    if ($op == OP_FINALLY) {
        $self->{findone} = ['last'];
        return $param[0]->($this);
    }

    pop @{ $self->{iter} };
    return $this->done();
}

sub throw {
    my ($this, $err) = @_;
    my $self = $SELF{refaddr $this};
    $err //= q{};

    $self->{findone} = undef;

    my ($nextop) = @{ $self->{opcode}[ $self->{pc} + 1 ] || [] };
    my $stack = $nextop && $nextop == OP_ENDTRY ? 1 : 0;
    while (++$self->{pc} <= $#{ $self->{opcode} }) {
        my $op = _op($self);
          $op == OP_CATCH   && !$stack      ? last
        : $op == OP_FINALLY && !$stack      ? last
        : $op == OP_TRY                     ? $stack++
        : $op == OP_ENDTRY                  ? $stack--
        : $op == OP_WHILE                   ? push @{ $self->{iter} }, [ 1, $self->{pc} ]
        : $op == OP_ENDWHILE                ? pop  @{ $self->{iter} }
        :                                     next;
    }

    if ($self->{pc} > $#{ $self->{opcode} }) {
        if ($self->{parent}) {
            return $self->{parent}->throw($err);
        } else {
            croak 'uncatched exception in Defer: '.$err;
        }
    }

    my ($op, @param) = _op($self);
    if ($op == OP_CATCH) {
        while (my ($cond, $code) = splice @param, 0, 2) {
            if ($err =~ /$cond/xms) {
                return $code->($this, $err);
            }
        }
        return $this->throw($err);
    }
    else { # OP_FINALLY
        $self->{findone} = ['throw', $err];
        return $param[0]->($this, $err);
    }
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Async::Defer - VM to write and run async code in usual sync-like way


=head1 SYNOPSIS

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
        # $d->next();
        # $d->last();
    });

    $defer->if(sub{ my $d=shift; return 1 });

      $defer->try();

        $defer->do($defer2);

      $defer->catch(
        qr/^io:/    => sub{
            my ($d,$err) = @_;
            # end with $d->done/throw/next/last
        },
        qr//        => sub{     # WILL CATCH ALL EXCEPTIONS
            my ($d,$err) = @_;
            # end with $d->done/throw/next/last
        },
        FINALLY     => sub{
            my ($d,$err,@result) = @_;
            # end with $d->done/throw/next/last
        },
      );

    $defer->else();

      $defer->while(sub{ my $d=shift; return $d->iter() <= 3 });

        $defer->do(sub{
            my ($d) = @_;
            # may access $d->iter() here
            # end with $d->done/throw/next/last
        });

      $defer->end_while();

    $defer->end_if();

    $defer->{anyvar} = 'anyval';

    # ... START

    $defer->run();


=head1 DESCRIPTION

B<WARNING: This is experimental code, public interface may change.>

This module's goal is to simplify writing complex async event-based code,
which usually mean huge amount of callback/errback functions, very hard to
support. It was initially inspired by Python/Twisted's Deferred object,
but go further and provide virtual machine which allow you to write/define
complete async program (which consists of many callback/errback) in sync
way, just like you write usual non-async programs.

Main idea is simple. For example, if you've this non-async code:

    $var = fetch_val();
    process_val( $var );

and want to make fetch_val() async, you usually do something like this:

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

These anon subs are similar to 'statements' in perl. Between these
'statements' you can use 'flow control' operators like if(), while() and
try()/catch(). And inside 'statements' you can control execution flow
using done(), throw(), next() and last() operators when current async
function will finish and will be ready to go to the next step.
Finally, you can use Async::Defer object to keep your 'local variables' -
this object is empty hash, and you can create any keys in it.
Single Defer object described this way is sort of single 'function'.
And it's possible to 'call' another functions by using another Defer
object as parameter for do() instead of usual anon sub.

While you can use both sync and async sub in do(), they all B<MUST> call
one of done(), throw(), next() or last() when they finish their work,
and do this B<ONLY ONCE>. This is Defer's way to proceed from one step to
another, and if not done right Defer object's behaviour is undefined!


=head2 PERSISTENT STATE, LOCAL VARIABLES and SCOPE

There are several ways to implement this, and it's unclear yet which
way is the best. We can implement full-featured stack with local variables
similar to perl's 'local' using getter/setter methods; we can fill called
Defer objects with copy of all keys in parent Defer object (so called
object will have full read-only access to parent's scalar data, and read/write
access to parent's reference data types); we can do nothing and let user
manually send all needed data to called Defer object as params and get
data back using returned values (by done() or throw()).

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
removed, so on second and next runs it will see internal data left by
previous runs. This may or may not be desirable behaviour. In later case
you should use clone() and run only clones of original object (clones are
created using C< %$clone=%$orig >, so they share only reference-type keys
which exists in original Defer):

    $d->do( $another_defer->clone() );
    $d->do( $another_defer->clone() );


=head1 EXPORTS

Nothing by default, but all documented functions can be explicitly imported.


=head1 INTERFACE 

=over

=item new()

Create and return Async::Defer object.

=item clone()

Clone existing Async::Defer object and return clone.

Clone will have same 'program' (STATEMENTS and OPERATORS added to original
object) and same 'local variables' (non-deep copy of orig object keys
using C< %$clone = %$orig >). After cloning these two objects can be
modified (by adding new STATEMENTS, OPERATORS and modifying variables)
independently.

It's possible to clone() object which is running right now, cloned object
will not be in running state - this is safe way to run() objects which may
or may not be already running.

=item run( [ $parent_defer, @params ] )

Start executing object's current 'program', which must be defined first by
adding at least one STATEMENT (do() or catch(FINALLY=>sub{})) to this object.

Usually while run() only first STATEMENT will be executed. It will just
start some async function and returns, and run() will returns immediately
after this too. Actual execution of this object will continue when started
async function will finish (usually on Timer or I/O event) and call this
object's done(), last(), next() or throw() methods.

It's possible to make all STATEMENTS sync - in this case full 'program'
will be executed before returning from run() - but this has no real sense
because you don't need Defer object for sync programs.

There will be no 'return value' at end of 'program', after last STATEMENT
in this object will call done() nothing else will happens and any parameters
of that last done() call will be ignored.

=item iter()

This method available only inside while() - both in while()'s \&conditional
argument and while()'s body STATEMENTS. It return current iteration number
for nearest while(), counting from 1.

    # this loop will execute 3 times:
    $d->while(sub{  shift->iter() <= 3  });
        $d->do(sub{
            my ($d) = @_;
            printf "Iteration %d\n", $d->iter();
            $d->done();
        });
    $d->end_while();

=back

=head2 STATEMENTS and OPERATORS

=over

=item do( \&sync_or_async_code )
=item do( $child_defer )

Add STATEMENT to this object's 'program'.

When this STATEMENT should be executed, \&sync_or_async_code (or
$child_defer's first STATEMENT) will be called with these params:

    ( $defer_object, @optional_results_from_previous_STATEMENT )

=item if( \&conditional )
=item else()
=item end_if()

Add conditional OPERATOR to this object's 'program'.

When this OPERATOR should be executed, \&conditional will be called with
single param:

    ( $defer_object )

The \&conditional B<MUST> be sync, and return true/false.

=item while( \&conditional )
=item end_while()

Add loop OPERATOR to this object's 'program'.

When this OPERATOR should be executed, \&conditional will be called with
single param:

    ( $defer_object )

The \&conditional B<MUST> be sync, and return true/false.

=item try()
=item catch( $regex_or_FINALLY => \&sync_or_async_code, ... )

Add exception handling to this object's 'program'.

In general, try/catch/finally behaviour is same as in Java (and probably
many other languages).

If some STATEMENTS inside try/catch block will throw(), the thrown error
can be intercepted (using matching regexp in catch()) and handled in any
way (blocked - if catch() handler call done(), next() or last() or
replaced by another exception - if catch() handler call throw()).
If exception match more than one regexp, first successfully matched
regexp's handler will be used. Handler will be executed with params:

    ( $defer_object, $error )

In addition to exception handlers you can also define FINALLY handler
(by using string "FINALLY" instead of regex). FINALLY handler will be
called in any case (with/without exception) and may handle this in any way
just like any other exception handler in catch(). FINALLY handler will
be executed with different params:

    # with exception
    ( $defer_object, $error)
    # without exception
    ( $defer_object, @optional_results_from_previous_STATEMENT )

=back

=head2 FLOW CONTROL for STATEMENTS

One, and only one of these methods B<MUST> be called at end of each STATEMENT,
both sync and async!

=over

=item done( @optional_result )

Go to next STATEMENT/OPERATOR. If next is STATEMENT, it will receive
@optional_result in it parameters.

=item throw( $error )

Throw exception. Nearest matching catch() or FINALLY STATEMENT will be
executed and receive $error in it parameter.

=item next()

Move to beginning of nearest while() (or to first STATEMENT if called outside
while()) and continue with next iteration (if while()'s \&conditional
still returns true).

=item last()

Move to first STATEMENT/OPERATOR after nearest while() (or finish this
'program' if called outside while() - returning to parent's Defer object
if any).

=back


=head1 BUGS AND LIMITATIONS

No bugs have been reported.


=head1 SUPPORT

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Async-Defer>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

You can also look for information at:

=over

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Async-Defer>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Async-Defer>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Async-Defer>

=item * Search CPAN

L<http://search.cpan.org/dist/Async-Defer/>

=back


=head1 AUTHOR

Alex Efros  C<< <powerman-asdf@ya.ru> >>


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Alex Efros <powerman-asdf@ya.ru>.

This program is distributed under the MIT (X11) License:
L<http://www.opensource.org/licenses/mit-license.php>

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

