{
  buildPythonPackage,
  lib,
  fetchPypi,
}:

buildPythonPackage rec {
  pname = "xstatic";
  version = "1.0.3";

  src = fetchPypi {
    pname = "XStatic";
    inherit version;
    sha256 = "sha256-QCVEzJ4XlIlEEFTwnIB4BOEV6iRpB96HwDVftPWjEmg=";
  };

  # no tests implemented
  doCheck = false;

  meta = with lib; {
    homepage = "https://bitbucket.org/thomaswaldmann/xstatic";
    description = "Base packaged static files for python";
    license = licenses.mit;
    maintainers = with maintainers; [ makefu ];
  };
}
