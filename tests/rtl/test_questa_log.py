import unittest

from questa_log import has_unexpected_diagnostics


class QuestaLogTests(unittest.TestCase):
    def test_known_warnings_in_both_transcript_formats(self):
        optimization = '** Warning: (vopt-10587) +acc disables some optimizations.'
        environment = 'Warning: (vsim-223) The environment variable MGC_HOME is set.'
        self.assertFalse(has_unexpected_diagnostics(f'# {optimization}\r\n{environment}'))

    def test_unknown_diagnostics_and_error_summary(self):
        for line in (
            '# ** Warning: (vsim-3015) Port size mismatch',
            '# ** Warning (suppressible): (vsim-3015) Port size mismatch',
            '# Warning: (vlog-223) Unexpected compiler warning',
            '# ** Error: Missing port',
            '# ** Error (suppressible): Bad connection',
            'Fatal: Simulation aborted',
            '# Errors: 2, Warnings: 0',
        ):
            with self.subTest(line=line):
                self.assertTrue(has_unexpected_diagnostics(line))

    def test_sva_warning_requires_explicit_opt_out(self):
        line = '# ** Warning: tb.sv(7): (vlog-2186) Concurrent assertion ignored'
        self.assertTrue(has_unexpected_diagnostics(line))
        self.assertFalse(has_unexpected_diagnostics(line, allow_no_sva=True))
        self.assertTrue(has_unexpected_diagnostics(line + '\n# Errors: 1', allow_no_sva=True))

    def test_success_and_tcl_echo(self):
        transcript = '# $display("Error: test marker")\n# PASS\n# Errors: 0, Warnings: 0'
        self.assertFalse(has_unexpected_diagnostics(transcript))
