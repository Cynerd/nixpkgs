# This file was generated by pkgs.mastodon.updateScript.
{ fetchFromGitHub, applyPatches, patches ? [] }:
let
  version = "4.3.0";
in
(
  applyPatches {
    src = fetchFromGitHub {
      owner = "mastodon";
      repo = "mastodon";
      rev = "v${version}";
      hash = "sha256-nZtxildQmT/7JMCTx89ZSWxb9I7xMLGHTJv7v4gfdd4=";
    };
    patches = patches ++ [];
  }) // {
  inherit version;
  yarnHash = "sha256-V/kBkxv6akTyzlFzdR1F53b7RD0NYtap58Xt5yOAbYA=";
}
