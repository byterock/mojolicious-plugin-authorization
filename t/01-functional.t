#!/usr/bin/env perl
use strict;
use warnings;
# Disable IPv6, epoll and kqueue
BEGIN { $ENV{MOJO_NO_IPV6} = $ENV{MOJO_POLL} = 1 }
use Test::More;
plan tests => 38;
# testing code starts here
use Mojolicious::Lite;
use Test::Mojo;
my %roles = (role1=>{priv1=>1},
             role2=>{privv1=>1,priv2=>1});
plugin 'authorization', {
 has_priv => sub {
     my $self = shift;
     my ($priv, $extradata) = @_;
     return 0
      unless($self->session('role'));
     my $role  = $self->session('role');
     my $privs = $roles{$role};
     return 1
       if exists($privs->{$priv});
     return 0;
  },
  is_role => sub {
    my $self = shift;
    my ($role, $extradata) = @_;
    return 0
       unless($self->session('role'));
    return 1
       if ($self->session('role') eq $role);
    return 0;
  },
  user_privs => sub {
    my $self = shift;
    my ($extradata) = @_;
    return []
       unless($self->session('role'));
    my $role  = $self->session('role');
    my $privs = $roles{$role};
    return keys(%{$privs});
  },
  user_role => sub {
    my $self = shift;
    my ($extradata) = @_;
    return $self->session('role');
   },
   
};
get '/' => sub {
    my $self = shift;
    $self->session('role'=>'role1');
    $self->render(text => 'index page');
};
get '/change/:role' => sub {
  my $self = shift;
  my $role =  $self->param('role');
  $self->session('role'=>$role);
  $self->stash('role_name'=> $self->role());
  $self->render('role');
 # $self->render(template);  ## this is called automatically
};
my $t = Test::Mojo->new;
$t->get_ok('/')->status_is(200)->content_is('index page');
$t->get_ok('/authonly')->status_is(200)->content_is('not authenticated');
$t->get_ok('/condition/authonly')->status_is(404);
# let's try this
$t->post_form_ok('/login', { u => 'fnark', p => 'fnork' })->status_is(200)->content_is('failed');
$t->get_ok('/authonly')->status_is(200)->content_is('not authenticated');
$t->post_form_ok('/login', { u => 'foo', p => 'bar' })->status_is(200)->content_is('ok');
$t->get_ok('/authonly')->status_is(200)->content_is('authenticated');
$t->get_ok('/condition/authonly')->status_is(200)->content_is('authenticated condition');
$t->get_ok('/logout')->status_is(200)->content_is('logout');
$t->get_ok('/authonly')->status_is(200)->content_is('not authenticated');
$t->post_form_ok('/login2', { u => 'foo', p => 'bar' })->status_is(200)->content_is('ok');
$t->get_ok('/authonly')->status_is(200)->content_is('authenticated');
$t->get_ok('/condition/authonly')->status_is(200)->content_is('authenticated condition');
