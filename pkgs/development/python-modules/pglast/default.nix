{
  lib,
  buildPythonPackage,
  fetchPypi,
  pythonOlder,
  setuptools,
  pytest,
  pytest-cov-stub,
}:

buildPythonPackage rec {
  pname = "pglast";
  version = "6.4";
  pyproject = true;

  disabled = pythonOlder "3.7";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-lyPwRcq5BR7E5YASn7NDmYU5TY/mgbvg45ZGYEWPmKg=";
  };

  build-system = [ setuptools ];

  dependencies = [ setuptools ];

  nativeCheckInputs = [
    pytest
    pytest-cov-stub
  ];

  # pytestCheckHook doesn't work
  # ImportError: cannot import name 'parse_sql' from 'pglast'
  checkPhase = ''
    pytest
  '';

  pythonImportsCheck = [
    "pglast"
    "pglast.parser"
  ];

  meta = with lib; {
    homepage = "https://github.com/lelit/pglast";
    description = "PostgreSQL Languages AST and statements prettifier";
    changelog = "https://github.com/lelit/pglast/blob/v${version}/CHANGES.rst";
    license = licenses.gpl3Plus;
    maintainers = [ ];
    mainProgram = "pgpp";
  };
}
