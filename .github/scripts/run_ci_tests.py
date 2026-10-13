"""Run the existing suite; surface failures in authenticated-independent CI annotations."""
import os
import unittest
import sys

def main():
    suite = unittest.defaultTestLoader.discover(".github/scripts", pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for test, traceback in result.failures + result.errors:
            # Fixture diagnostics only; never dump environment or request credentials.
            message = (str(test) + "\n" + traceback)[-16000:]
            message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print("::error title=Regression test failed::" + message, flush=True)
    return 0 if result.wasSuccessful() else 1

if __name__ == "__main__":
    sys.exit(main())
