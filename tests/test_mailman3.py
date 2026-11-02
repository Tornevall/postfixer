import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import os

spec = importlib.util.spec_from_file_location('mailman3_installer', Path(__file__).resolve().parents[1] / 'bin/mailman3.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mspec = importlib.util.spec_from_file_location('mailman3_migrate', Path(__file__).resolve().parents[1] / 'bin/mailman3-migrate.py')
migration = importlib.util.module_from_spec(mspec)
mspec.loader.exec_module(migration)


class InstallerTests(unittest.TestCase):
    def test_optional_installation_decisions(self):
        helper = Path(__file__).resolve().parents[1] / 'bin/mailman3-options.sh'
        for role, requested, installed, interactive, expected in [
            ('inout', 'auto', 'no', 'yes', 'ask'),
            ('inout', 'auto', 'no', 'no', 'no'),
            ('inout', 'yes', 'no', 'no', 'yes'),
            ('inout', 'auto', 'yes', 'yes', 'keep'),
            ('inout', 'no', 'yes', 'yes', 'no'),
            ('relay', 'auto', 'no', 'yes', 'no')]:
            cmd = 'source "$1"; mailman3_install_decision "$2" "$3" "$4" "$5"'
            with self.subTest(role=role, requested=requested, installed=installed):
                self.assertEqual(subprocess.check_output(['bash', '-c', cmd, 'test', str(helper), role, requested, installed, interactive], text=True).strip(), expected)
        self.assertNotEqual(subprocess.run(['bash', '-c', cmd, 'test', str(helper), 'relay', 'yes', 'no', 'no'], capture_output=True).returncode, 0)
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


class MigrationTests(unittest.TestCase):
    @unittest.skipUnless(os.geteuid() == 0, 'root-only staging command')
    def test_fetch_is_non_deleting_private_and_uses_batch_ssh(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder); binaries = base / 'bin'; binaries.mkdir()
            (binaries / 'ssh').write_text('#!/bin/sh\nexit 0\n')
            (binaries / 'rsync').write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_RSYNC_LOG"\n')
            for p in binaries.iterdir(): p.chmod(0o755)
            env = {**os.environ, 'PATH': str(binaries) + ':/usr/bin:/bin',
                   'REMOTE': 'root@original.example', 'MAILMAN_STAGE': str(base / 'stage'),
                   'TEST_RSYNC_LOG': str(base / 'arguments')}
            script = Path(__file__).resolve().parents[1] / 'bin/mailman3-fetch.sh'
            subprocess.run(['bash', str(script)], env=env, check=True, capture_output=True)
            args = (base / 'arguments').read_text()
            self.assertNotIn('--delete', args)
            self.assertIn('BatchMode=yes', args)
            self.assertIn('root@original.example:/var/lib/mailman/', args)
            self.assertEqual((base / 'stage').stat().st_mode & 0o777, 0o700)

    def test_inventory_finds_config_mbox_and_html_without_loading_pickle(self):
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder)
            (stage / 'lists/demo').mkdir(parents=True)
            (stage / 'lists/demo/config.pck').write_bytes(b'not-a-valid-pickle')
            (stage / 'archives/private/demo.mbox').mkdir(parents=True)
            (stage / 'archives/private/demo.mbox/demo.mbox').write_bytes(b'archive')
            (stage / 'archives/private/demo').mkdir()
            rows = migration.inventory(stage)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['list'], 'demo')
            self.assertEqual(rows[0]['mbox_bytes'], 7)
            self.assertTrue(rows[0]['legacy_html_present'])

    def test_symlink_cannot_import_config_outside_staging(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            stage = Path(folder)
            (stage / 'lists/demo').mkdir(parents=True)
            external = Path(outside) / 'secret'; external.write_text('not staged')
            (stage / 'lists/demo/config.pck').symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'escapes'):
                migration.inventory(stage)

    def test_import_requires_review_and_frozen_source_before_any_service_action(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(migration, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'freeze'):
                migration.import_list(Path('/nonexistent'), 'demo')
            run.assert_not_called()

    def test_list_name_rejects_path_traversal(self):
        for name in ['../demo', '/demo', 'a/../b', 'a..b', 'x;id']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                migration.valid_list(name)



class PublicArchiveTests(unittest.TestCase):
    def test_legacy_archives_are_closed_without_explicit_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIn('return 404', m.legacy_archive_location(Path(folder) / 'missing'))

    def test_only_a_reviewed_public_subdirectory_can_be_exposed(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder); public = base / 'www'; public.mkdir()
            selected = public / 'archives'; selected.mkdir()
            marker = base / 'marker'; marker.write_text(str(selected))
            result = m.legacy_archive_location(marker, public)
            self.assertIn('disable_symlinks on', result)
            self.assertIn(str(selected), result)
            for wrong in [base, public]:
                marker.write_text(str(wrong))
                with self.assertRaises(RuntimeError): m.legacy_archive_location(marker, public)
            outside = base / 'private'; outside.mkdir()
            link = public / 'link'; link.symlink_to(outside)
            marker.write_text(str(link))
            with self.assertRaises(RuntimeError): m.legacy_archive_location(marker, public)

if __name__ == '__main__':
    unittest.main()
