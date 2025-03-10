Test that dune will add checksums to lockfiles when the package has a source
archive but no checksum.
  $ . ./helpers.sh
  $ mkrepo

  $ strip_pwd() {
  >   sed -e "s#$PWD#<pwd>#"
  > }

  $ echo "Hello, World!" > foo.txt

  $ mkpkg foo <<EOF
  > url {
  >  src: "$PWD/foo.txt"
  > }
  > EOF

  $ solve foo | strip_pwd
  Solution for dune.lock:
  - foo.0.0.1
  Package "foo" has source archive which lacks a checksum.
  The source archive will be downloaded from:
  file://<pwd>/foo.txt
  Dune will compute its own checksum for this source archive.

Replace the path in the lockfile as it would otherwise include the sandbox
path.
  $ cat dune.lock/foo.pkg | strip_pwd
  (version 0.0.1)
  
  (source
   (fetch
    (url
     file://<pwd>/foo.txt)
    (checksum md5=bea8252ff4e80f41719ea13cdf007273)))

Now make sure we can gracefully handle the case when the archive is missing.

  $ rm foo.txt
  $ solve foo 2>&1 | strip_pwd
  Package "foo" has source archive which lacks a checksum.
  The source archive will be downloaded from:
  file://<pwd>/foo.txt
  Dune will compute its own checksum for this source archive.
  Warning: Failed to retrieve source archive from:
  file://<pwd>/foo.txt
  Solution for dune.lock:
  - foo.0.0.1
  $ cat dune.lock/foo.pkg | strip_pwd
  (version 0.0.1)
  
  (source
   (fetch
    (url
     file://<pwd>/foo.txt)))
