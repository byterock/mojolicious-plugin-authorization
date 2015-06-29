# NAME

Mojolicious::Plugin::Authorization - A plugin to make Authorization a bit easier

# VERSION

version 1.03

# SYNOPSIS

    use Mojolicious::Plugin::Authorization
    $self->plugin('Authorization' => {
        'has_priv'    => sub { ... },
        'is_role'     => sub { ... },
        'user_privs'  => sub { ... },
        'user_role'   => sub { ... },
        'fail_render' => { status => 401, json => { ... } },
    });
    if ($self->has_priv('delete_all', { optional => 'extra data stuff' })) {
        ...
    }

# DESCRIPTION

A very simple API implementation of role-based access control (RBAC). This plugin is only an API you will
have to do all the work of setting up your roles and privileges and then provide four subs that are used by
the plugin.
The plugin expects that the current session will be used to get the role its privileges. It also assumes that
you have already been authenticated and your role set.
That is about it you are free to implement any system you like.

# METHODS

## has\_priv('privilege', $extra\_data) or has\_privilege('privilege', $extra\_data)

'has\_priv' and 'has\_privilege' will use the supplied `has_priv` subroutine ref to check if the current session has the
given privilege. Returns true when the session has the privilege or false otherwise.
You can pass additional data along in the extra\_data hashref and it will be passed to your `has_priv`
subroutine as-is.

## is('role',$extra\_data) / is\_role('role,$extra\_data)

'is' / 'is\_role' will use the supplied `is_role` subroutine ref to check if the current session is the
given role. Returns true when the session has privilege or false otherwise.
You can pass additional data along in the extra\_data hashref and it will be passed to your `is_role`
subroutine as-is.

## privileges($extra\_data)

'privileges' will use the supplied `user_privs` subroutine ref and return the privileges of the current session.
You can pass additional data along in the extra\_data hashref and it will be passed to your `user_privs`
subroutine as-is. The returned data is dependent on the supplied `user_privs` subroutine.

## role($extra\_data)

'role' will use the supplied `user_role` subroutine ref and return the role of the current session.
You can pass additional data along in the extra\_data hashref and it will be passed to your `user_role`
subroutine as-is. The returned data is dependent on the supplied `user_role` subroutine.

# CONFIGURATION

The following options must be set for the plugin:

- has\_priv (REQUIRED) A coderef for checking to see if the current session has a privilege (see ["HAS PRIV"](#has-priv)).
- is\_role (REQUIRED) A coderef for checking to see if the current session is a certain role (see ["IS / IS ROLE"](#is-is-role)).
- user\_privs (REQUIRED) A coderef for returning the privileges of the current session (see ["PRIVILEGES"](#privileges)).
- user\_role (REQUIRED) A coderef for retiring the role of the current session (see ["ROLE"](#role)).

The following options are not required but allow greater control:

- fail\_render (OPTIONAL) A hashref for setting the status code and rendering json/text/etc when routing fails (see ["ROUTING VIA CALLBACK"](#routing-via-callback)).

## HAS PRIV

'has\_priv' is used when you need to confirm that the current session has the given privilege.
The coderef you pass to the `has_priv` configuration key has the following signature:

    sub {
        my ($app, $privilege,$extradata) = @_;
        ...
    }

You must return either 0 for a fail and 1 for a pass.  This allows `ROUTING VIA CONDITION` to work correctly.

## IS / IS ROLE

'is' / 'is\_role' is used when you need to confirm that the current session is set to the given role.
The coderef you pass to the `is_role` configuration key has the following signature:

    sub {
        my ($app, $role, $extradata) = @_;
        ...
        return $role;
    }

You must return either 0 for a fail and 1 for a pass.  This allows `ROUTING VIA CONDITION` to work correctly.

## PRIVILEGES

'privileges' is used when you need to get all the privileges of the current session.
The coderef you pass to the `user_privs` configuration key has the following signature:

    sub {
        my ($app,$extradata) = @_;
        ...
        return $privileges;
    }

You can return anything you want. It would normally be an arrayref of privileges but you are free to
return a scalar, hashref, arrayref, blessed object, or undef.

## ROLE

'role' is used when you need to get the role of the current session.
The coderef you pass to the `user_privs` configuration key has the following signature:

    sub {
        my ($app,$extradata) = @_;
        ...
        return $role;
    }

You can return anything you want. It would normally be just a scalar but you are free to
return a scalar, hashref, arrayref, blessed object, or undef.

# EXAMPLES

For a code example using this, see the `t/01-functional.t` test,
it uses [Mojolicious::Lite](https://metacpan.org/pod/Mojolicious::Lite) and this plugin.

# ROUTING VIA CONDITION

This plugin also exports a routing condition you can use in order to limit access to certain documents to only
sessions that have a privilege.

    $r->route('/delete_all')->over(has_priv => 'delete_all')->to('mycontroller#delete_all');
    my $delete_all_only = $r->route('/members')->over(has_priv => 'delete_all')->to('members#delete_all');
    $delete_all_only->route('delete')->to('members#delete_all');

If the session does not have the 'delete\_all' privilege, these routes will not be considered by the dispatcher and unless you have set up a catch-all route,
 a 404 Not Found will be generated instead.

Another condition you can use to limit access to certain documents to only those sessions that
have a role.

    $r->route('/view_all')->over(is => 'ADMIN')->to('mycontroller#view_all');
    my $view_all_only = $r->route('/members')->over(is => 'view_all')->to('members#view_all');
    $view_all_only->route('view')->to('members#view_all');

If the session is not the 'ADMIN' role, these routes will not be considered by the dispatcher and unless you have set up a catch-all route,
 a 404 Not Found will be generated instead.
This behavior is similar to the "has" condition.

# ROUTING VIA CALLBACK

It is not recommended to route un-authorized requests to anything but a 404 page. If you do route to some sort
of 'You are not allowed page' you are telling a hacker that the URL was correct while the 404 tells them nothing.
This is just my opinion.

However in the case of publicly documented APIs returning a 404 when priv/role checks fails can confuse users, so
you can override the default 404 status on failure by supplying a 'fail\_render' value in the plugin config. This
will be passed to the Mojolicious ->render method when the has\_priv/is/is\_role routing fails. For example, to
return a status code of 401 with JSON:

    fail_render => { status => 401, json => { error => 'Denied' } },

# SEE ALSO

[Mojolicious::Sessions](https://metacpan.org/pod/Mojolicious::Sessions), [Mojocast 3: Authorization](http://mojocasts.com/e3#)

# AUTHOR

John Scoles, `<byterock  at hotmail.com>`

# BUGS / CONTRIBUTING

Please report any bugs or feature requests through the web interface at [https://github.com/byterock/mojolicious-plugin-authorization/issues](https://github.com/byterock/mojolicious-plugin-authorization/issues).

# SUPPORT

You can find documentation for this module with the perldoc command.
    perldoc Mojolicious::Plugin::Authorization
You can also look for information at:

- AnnoCPAN: Annotated CPAN documentation [http://annocpan.org/dist/Mojolicious-Plugin-Authorization](http://annocpan.org/dist/Mojolicious-Plugin-Authorization)
- CPAN Ratings [http://cpanratings.perl.org/d/Mojolicious-Plugin-Authorization](http://cpanratings.perl.org/d/Mojolicious-Plugin-Authorization)
- Search CPAN [http://search.cpan.org/dist/Mojolicious-Plugin-Authorization/](http://search.cpan.org/dist/Mojolicious-Plugin-Authorization/)

# ACKNOWLEDGEMENTS

Ben van Staveren   (madcat)

    -   For 'Mojolicious::Plugin::Authentication' which I used as a guide in writing up this one.

Chuck Finley

    -   For staring me off on this.

Abhijit Menon-Sen

    -   For the routing suggestions

Roland Lammel

    -   For some other good suggestions

# LICENSE AND COPYRIGHT

Copyright 2012 John Scoles.
This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.
See http://dev.perl.org/licenses/ for more information.
