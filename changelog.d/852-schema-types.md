### Internal
- **Every Ecto schema defines a `t` type (#852).** Typespecs named `Movie.t()`, `BookTarget.t()`
  and twelve other schema types that did not exist. A test now fails when a typespec in Cinder
  names a remote type that its module does not define as public.
