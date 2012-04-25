#!/usr/bin/env perl
use strict;
use warnings;
use warnings FATAL => qw{ uninitialized };
use autodie;
use lib qw( C:\johns\Mojolicious\Plugins\Authorization\example
             );
# Disable IPv6, epoll and kqueue
BEGIN { $ENV{MOJO_NO_IPV6} = $ENV{MOJO_POLL} = 1 }
use Mojolicious::Lite;
=pod
=head1 Title
  showoff-authorization.pl --- an example of the Mojolicious::Plugin::Authorization module by John Scoles
=head1 Invocation
  $ perl showoff-authorization.pl daemon
=head1 Notes
My first crack at a Mojo plugin a steal from Ben van Staveren's Authentication so I owe him and some others
a great note of thanks
Like Authentication this is a very a simple application. It supplies the framwork and you have to give it
the guts which this little progam shows.
I did not add in any Authentication as that is up to you to build. In this test I just assume you are
autnticated on the session ans that session has a role hash on it.
=head1 Versions
  0.0: Apr 24 2012
=cut
################################################################
### miniauthorfile.pm lays out basic functionality for the miniauthorfile
use miniauthorfile;
my $roles = miniauthorfile->new('miniauthorfile.txt');
################################################################
plugin 'authorization', {
			  has_priv => sub {
			    my $self = shift;
			    my ($priv, $extradata) = @_;
			    my $session_privs = $self->session('role');
			    return 1
			      if exists($session_privs->{$priv});
			    return 0;
			  },
			  is_role => sub {
			    my $self = shift;
			    my ($role, $extradata) = @_;
			    return 1;
			  },
			  user_privs => sub {
			    my $self = shift;
			    my ($extradata) = @_;
			    return $self->session('role');
			  },
			  user_role => sub {
			    my $self = shift;
			    my ($extradata) = @_;
			    return $self->session('role');
			  },
			 };
################################################################
get '/' => sub {
  my $self = shift;
  $self->stash(
	       userid => $self->user() || "not logged in");
  $self->render('index');  ## index needs to be named to match '/'
};
get '/loginpanel' => sub {
  my $self = shift;
  $self->stash(
	       userid => $self->user() || "not logged in");
  # $self->render(template);  ## this is called automatically
};
post '/loginresponse' => sub {
  my $self = shift;
  print
  $self->stash(loginstatus => ( ($self->authenticate($self->req->param('u'), $self->req->param('p'))) ? "success" : "failure" ),
	       userid => $self->user() || "not logged in");
};
get '/logout' => sub {
  my $self = shift;
  $self->logout();
  $self->render(text => 'You are logged out.');
};
############ these two subs can show you what you can do now, based on authenticated status
get '/doyouknowme' => sub {
  my $self = shift;
  $self->stash( isauthenticated => ($self->user_exists) ? 'authenticated' : 'not authenticated',
		userid => $self->user() || "not logged in");
};
## /condition/authonly exists as a webpage ONLY after authentication
get '/ifknown/index.html' => (authenticated => 1) => sub {
  my $self = shift;
  $self->render(text => 'the /ifknown/index.html page exists at the moment',
		userid => $self->user() || "not logged in");
};
app->secret('Your own super-secret passphrase.');  # used for cookies and persistence
app->start();
################################################################
__DATA__
@@ index.html.ep
% layout 'default';
% title 'Root';
<h2> Top Index Page</h2>
<p>The purpose of this little web app is to show an example of <a href="http://mojolicio.us/">Mojolicious</a> and its <a href="http://search.cpan.org/~madcat/Mojolicious-Plugin-Authentication/">Mojolicious::Authentication module</a> by Ben van Staveren.</p>
<p>Start by browsing to the <a href="/loginpanel">login panel</a>.</p>
@@ loginpanel.html.ep
% layout 'default';
% title 'Login Panel';
<p>This is your login panel.</p>
<p>There are currently <%= $numusers %> registered users.  We hope you are one of them.</p>
<form action="/loginresponse" method="post">
<table>
<tr> <td> User </td> <td> <input type="text" name="u" /> </td> </tr>
<tr> <td> Password </td> <td> <input type="text" name="p" /> </td> </tr>
</table>
<input type="submit" name="mysubmit" value="Click!" />
</form>
@@ loginresponse.html.ep
% layout 'default';
% title 'Login Response';
<h1>Login Response</h1>
<p>You are now <b><%= $userid %></b>.</p>
<p>I was told by a little gremlin that your login request returned <b><%= $loginstatus %></b>.</p>
<ul>
<li>You can now ask whether you are authenticated here: <a href="/doyouknowme">/doyouknowme</a>.</li>
<li>You can now see whether an authenticated-only webpage is available to you: <a href="/ifknown/index.html">/ifknown/index.html</a>.</li>
<li>Or you can log out again: <a href="/logout">/logout</a>.</li>
</ul>
@@ doyouknowme.html.ep
% layout 'default';
% title 'Do You Know Me?';
<h1>Do you know me?</h1>
<p>I was told by a little gremlin that you are <b><%= $isauthenticated %></b>.</p>
@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title><%= title %></title>
  </head>
  <body>
    <hr />
    <h1> Mojolicious: <%= $0 %>: <%= title %> </h1>
    <hr />
    <%= content %>
    <hr />
  <p style="font-size:small">Logged in as user <b><%= $userid %></b> &mdash; <a href="/logout">/logout</a></p>
  </body>
</html>
