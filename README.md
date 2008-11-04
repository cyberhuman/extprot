
## Introduction

extprot allows you to create compact, efficient, extensible, binary protocols
that can be used for cross-language communication and long-term data
serialization.  extprot supports protocols with rich, composable types, whose
definition can evolve while keeping both forward and backward compatibility.

The extprot compiler (extprotc) takes a protocol description and generates
code in any of the supported languages to serialize and deserialize the
associated data structures. It is accompanied by a runtime library for each
target language which is used to read and write the structures defined by the
protocol.

The protocols defined with extprot are:

* extensible: types can be extended in several ways without breaking
  compatibility with existent producers/consumers
* compact 
* fast: can be deserialized one to two orders of magnitude faster than XML

## Example

Here's a trivial protocol definition:

    (* this is a comment (* and this a nested comment *) *)
    message user = {
      id : int;
      name : string;
    }

The code generated by extprotc allows you to manipulate such messages as any
normal value. For instance, in the Ruby target (in progress as of 2008-11-04),
you'd do:

    # writing
    puts "About to save record for user #{user.name}"
    user.write(buf)
    # save buf

    # reading
    user = User.read(io)
    puts "Got user #{user.id} #{user.name}"


## Extensions

The protocol can be extended in several ways, only a few of which will be
shown here.

### New message fields

Suppose we find out some time later we also need the email and the age:

    message user = {
      id : int;
      name : string;
      email : string;
      age : int
    }

### New tuple elements

Then we realize that all users have at least an email, but maybe more, so we
extend the message again:

    message user = {
      id : int;
      name : string;
      email : (string * [string]);  (* at least one email, maybe more *)
      age : int
    }

The email field is now a tuple with two elements, the first one being a
string, and the second one a list of strings that might be empty (in this
case, the user has got only one email).

### Disjoint unions

Imagine our application has got several user types:

* free user
* paying user: we also want to record the end of the subscription period

This can be captured in the following type definition:
 
    type date = float (* time in seconds since the start of the epoch  *)
    
    type user_type = Free | Paying date 
		            (* could be written as  Paying float *)
    
    message user = {
      id : int;
      name : string;
      emails : (string * [string]);  (* at least one email, maybe more *)
      age : int;
      user_type : user_type
    }

That's not all: we then decide that all users qualify for a discount rate one
time starting from now.

    (* whether we will offer a discount rate in the next renewal *)
    type discount = Yes | No 

    type user_type = Free | Paying date discount

    (* same user definition as above *)

Old records of paying users have no discount element in their user_type field,
so the value will default to "Yes" when it is read by new consumers --- if we
wanted it to be "No" by default, we'd simply have to define the discount type
as

    type discount = No | Yes

### Polymorphic types

After a while, we have several message definitions, and realize that the "at
least one" pattern happens often. We can use a polymorphic type to avoid
having to type "(x * [x])" again and again:

    type one_or_more 'x = ('x * ['x])
    
    message user = {
      id : int;
      name : string;
      emails : one_or_more<string>;
      age : int;
      user_type : user_type;
    }
