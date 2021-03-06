# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, alex, filepath, happy, syb }:

cabal.mkDerivation (self: {
  pname = "language-c";
  version = "0.4.7";
  sha256 = "1r0jlncv6d6ai8kblrdq9gz8abx57b24y6hfh30xx20zdgccjvaz";
  buildDepends = [ filepath syb ];
  buildTools = [ alex happy ];
  meta = {
    homepage = "http://www.sivity.net/projects/language.c/";
    description = "Analysis and generation of C code";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
