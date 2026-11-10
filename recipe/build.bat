@echo on

:: Strip the "lib" prefix to produce aria2.lib for MSVC compatibility
set "REMOVE_LIB_PREFIX=1"

:: Invoke official conda-forge autotools clang build wrapper
call "%BUILD_PREFIX%\Library\bin\run_autotools_clang_conda_build.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
