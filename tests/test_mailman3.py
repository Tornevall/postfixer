import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mailman3_installer', Path(__file__).resolve().parents[1] / 'bin/mailman3.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class InstallerTests(unittest.TestCase):
    def test_existing_maps_preserved_and_our_map_not_duplicated(self):
        item = 'hash:/opt/mailman/data/postfix_lmtp'
        old = 'hash:/etc/postfix/transport, regexp:/etc/postfix/extra'
        new = m.prepend_map(old, item)
        self.assertIn('hash:/etc/postfix/transport', new)
        self.assertIn('regexp:/etc/postfix/extra', new)
        self.assertEqual(m.prepend_map(new, item), new)

    def test_host_configuration_preserved_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'settings.py'
            original = b'# operator config\r\nSECRET_KEY = "keep"\r\n'
            p.write_bytes(original)
            m.write_new(p, 'replacement')
            self.assertEqual(p.read_bytes(), original)

    def test_domain_rejects_nginx_config_or_command_injection(self):
        for value in ['x; return 200', 'example.org\n}', '*.example.org', '-bad.example', 'example..org', '$(hostname).org']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.validate_domain(value)
        self.assertEqual(m.validate_domain('lists.example.org'), 'lists.example.org')

    def test_relay_domains_without_recipient_policy_fail_before_postfix_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / 'mailman.cfg').write_text('configured')
            (base / 'domain').write_text('lists.example.org')
            (base / 'postfix_lmtp.db').touch()
            values = {'mydestination': 'localhost', 'virtual_alias_domains': '',
                      'virtual_mailbox_domains': '', 'relay_recipient_maps': '',
                      'relay_domains': 'other.example.org'}
            with patch.object(m, 'CONFIG', base), patch.object(m, 'MAPS', base), \
                    patch.object(m, 'output', side_effect=lambda *a: values[a[-1]]), \
                    patch.object(m, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'recipient validation'):
                    m.configure_postfix()
                run.assert_not_called()

    def test_postfix_maps_preserve_existing_routes_and_recipients(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / 'mailman.cfg').write_text('configured')
            (base / 'domain').write_text('lists.example.org')
            (base / 'postfix_lmtp.db').touch()
            values = {'mydestination': 'localhost', 'virtual_alias_domains': '',
                      'virtual_mailbox_domains': '',
                      'relay_recipient_maps': 'hash:/etc/postfix/recipients',
                      'relay_domains': 'other.example.org',
                      'transport_maps': 'hash:/etc/postfix/transport'}
            with patch.object(m, 'CONFIG', base), patch.object(m, 'MAPS', base), \
                    patch.object(m, 'output', side_effect=lambda *a: values[a[-1]]), \
                    patch.object(m, 'run') as run:
                m.configure_postfix()
                calls = [c.args for c in run.call_args_list]
                self.assertTrue(any('transport_maps = hash:' + str(base / 'postfix_lmtp') + ', hash:/etc/postfix/transport' in c for c in calls))
                self.assertTrue(any('relay_recipient_maps = hash:' + str(base / 'postfix_lmtp') + ', hash:/etc/postfix/recipients' in c for c in calls))


if __name__ == '__main__':
    unittest.main()
