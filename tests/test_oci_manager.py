"""OCI failure-path checks: stdlib unittest, no live cloud mutations."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace as NS
import unittest
from unittest.mock import Mock, patch

import oci
import yaml

spec = importlib.util.spec_from_file_location('oci_manager', Path(__file__).resolve().parents[1] / 'scripts/oci_manager.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def response(data):
    return oci.response.Response(200, {}, data, None)


def error(message='Out of host capacity.', status=500):
    return oci.exceptions.ServiceError(status, 'InternalError', {'opc-request-id': 'test-request'}, message)


def sdk_list_names(*clients):
    # Oracle's pagination retry helper inspects the callable's __name__.
    for client in clients:
        for name in ('list_instances', 'list_subnets', 'list_private_ips', 'list_region_subscriptions', 'list_compartments', 'list_availability_domains', 'list_volumes', 'list_boot_volumes', 'list_limit_definitions', 'list_vnic_attachments', 'list_boot_volume_attachments', 'list_route_tables'):
            getattr(client, name).__name__ = name


def instance(id='ocid1.instance.oc1.test', tag=None, state='RUNNING'):
    return NS(id=id, display_name='qbot', availability_domain='AD-2', compartment_id='ocid1.tenancy.oc1.test', lifecycle_state=state, freeform_tags={m.TAG: tag} if tag else {}, shape='VM.Standard.A1.Flex', shape_config=NS(ocpus=1, memory_in_gbs=6))


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = m.Store(self.tmp.name)
        self.cfg = {'name': 'qbot', 'region': 'us-chicago-1', 'compartment_id': 'ocid1.tenancy.oc1.test', 'mode': 'free-only', 'image': {'id': 'ocid1.image.test'}, 'shape': 'VM.Standard.A1.Flex', 'ocpus': 2, 'memory_gbs': 8, 'ssh': {'username': 'ubuntu'}, 'network': {'existing': {'subnet_id': 'ocid1.subnet.test'}}, 'capacity_attempts_per_ad': 1}
        self.compute, self.network, self.identity = Mock(), Mock(), Mock()
        sdk_list_names(self.compute, self.network, self.identity)
        self.identity.list_compartments.return_value = response([])
        self.api = {'compute': self.compute, 'network': self.network, 'identity': self.identity}
        self.manager = m.Manager({'tenancy': self.cfg['compartment_id'], 'region': 'us-chicago-1'}, self.store, lambda region: self.api)
        self.record = self.store.for_config(self.cfg)
        self.record.update(image_id='ocid1.image.test', plugins=['Compute Instance Monitoring', 'Compute Instance Run Command'], network={'vcn': {'id': 'ocid1.vcn.test', 'owned': False}, 'subnet': {'id': 'ocid1.subnet.test', 'owned': False}})
        self.store.save(self.record)
        self.compute.list_instances.return_value = response([])
        self.image = NS(id='ocid1.image.test', operating_system='Canonical Ubuntu', operating_system_version='24.04', display_name='Ubuntu-aarch64', compartment_id=None, size_in_mbs=47694)
        self.shapes = {'AD-1': NS(processor_description='Ampere', billing_type='LIMITED_FREE'), 'AD-2': NS(processor_description='Ampere', billing_type='LIMITED_FREE')}
        self.manager.ssh_key = Mock(return_value='ssh-ed25519 AAAA')
        self.manager.ads = Mock(return_value=['AD-1', 'AD-2'])
        self.manager.image_shapes = Mock(return_value=(self.image, self.shapes))
        self.manager.free_check = Mock(return_value=self.shapes)
        self.manager.network = Mock(return_value=NS(availability_domain=None))
        self.manager.finish = Mock()

    def test_capacity_fallback_saves_id_before_verification(self):
        self.compute.launch_instance.side_effect = [error(), response(instance())]
        self.manager.launch(self.cfg)
        calls = self.compute.launch_instance.call_args_list
        self.assertEqual([x.args[0].availability_domain for x in calls], ['AD-1', 'AD-2'])
        self.assertNotEqual(calls[0].kwargs['opc_retry_token'], calls[1].kwargs['opc_retry_token'])
        saved = self.store.records()[0]
        self.assertEqual(saved['instance_id'], instance().id)
        self.assertNotIn('pending', saved)
        self.assertEqual(saved['attempts'][0]['outcome'], 'capacity')
        self.manager.finish.assert_called_once()

    def test_capacity_exhaustion_is_bounded(self):
        self.compute.launch_instance.side_effect = error()
        with self.assertRaisesRegex(m.Error, 'Out of host capacity'):
            self.manager.launch(self.cfg)
        self.assertEqual(self.compute.launch_instance.call_count, 2)
        self.assertEqual(self.store.records()[0]['progress'], 'capacity-exhausted')
        self.assertNotIn('instance_id', self.store.records()[0])

    def test_ambiguous_response_replays_same_ad_payload_and_token(self):
        self.compute.launch_instance.side_effect = [TimeoutError(), response(instance())]
        with self.assertRaisesRegex(m.Error, 'unresolved'):
            self.manager.launch(self.cfg)
        pending = self.store.records()[0]['pending']
        self.assertEqual(self.compute.launch_instance.call_count, 1)
        self.manager.launch(self.cfg)
        second = self.compute.launch_instance.call_args
        self.assertEqual(second.args[0].availability_domain, pending['ad'])
        self.assertEqual(second.kwargs['opc_retry_token'], pending['token'])
        self.assertEqual(m.digest(oci.util.to_dict(second.args[0])), pending['payload_hash'])

    def test_expired_ambiguous_token_never_creates(self):
        self.record['pending'] = {'ad': 'AD-1', 'token': 'old-token', 'token_time': time.time() - 86401}
        self.store.save(self.record)
        with self.assertRaisesRegex(m.Error, 'too old'):
            self.manager.launch(self.cfg)
        self.compute.launch_instance.assert_not_called()

    def test_lost_response_reconciles_tag_without_new_launch(self):
        self.compute.list_instances.return_value = response([instance(tag=self.record['launch_id'])])
        self.manager.launch(self.cfg)
        self.compute.launch_instance.assert_not_called()
        self.assertEqual(self.store.records()[0]['instance_id'], instance().id)

    def test_saved_instance_with_ssh_failure_does_not_relaunch(self):
        self.record.update(instance_id=instance().id, progress='ssh-verification-failed')
        self.store.save(self.record)
        self.manager.launch(self.cfg)
        self.compute.launch_instance.assert_not_called()
        self.manager.finish.assert_called_once()

    def test_unrecorded_name_conflict_is_not_adopted(self):
        self.compute.list_instances.return_value = response([instance()])
        with self.assertRaisesRegex(m.Error, 'unrecorded'):
            self.manager.launch(self.cfg)
        self.compute.launch_instance.assert_not_called()

    def test_changed_config_cannot_create_new_retry_payload(self):
        changed = copy.deepcopy(self.cfg)
        changed['memory_gbs'] = 10
        with self.assertRaisesRegex(m.Error, 'Configuration changed'):
            self.manager.launch(changed)
        self.compute.launch_instance.assert_not_called()

    def test_ambiguous_recorded_name_requires_ocid(self):
        other = dict(self.record, record_id='other', region='us-phoenix-1', instance_id='ocid1.instance.other')
        self.store.save(other)
        with self.assertRaisesRegex(m.Error, 'Ambiguous'):
            self.manager.resolve('qbot')
        self.compute.get_instance.assert_not_called()

    def test_reused_network_is_never_deleted(self):
        self.manager.cleanup(self.record, self.api)
        self.assertFalse(self.network.mock_calls)

    def test_owned_subnet_with_private_ips_is_preserved(self):
        self.record['network']['subnet']['owned'] = True
        self.network.list_subnets.return_value = response([NS(id='ocid1.subnet.test', lifecycle_state='AVAILABLE')])
        self.network.get_subnet.return_value = response(NS(id='ocid1.subnet.test', freeform_tags={m.TAG: self.record['launch_id']}))
        self.network.list_private_ips.return_value = response([NS(id='ocid1.privateip.used')])
        with self.assertRaisesRegex(m.Error, 'private IPs'):
            self.manager.cleanup(self.record, self.api)
        self.network.delete_subnet.assert_not_called()

    def test_missing_ownership_tag_is_preserved(self):
        self.record['network']['subnet']['owned'] = True
        self.network.list_subnets.return_value = response([])
        self.network.get_subnet.return_value = response(NS(id='ocid1.subnet.test', freeform_tags={}))
        with self.assertRaisesRegex(m.Error, 'Ownership tag'):
            self.manager.cleanup(self.record, self.api)
        self.network.delete_subnet.assert_not_called()

    def test_cleanup_deletes_only_tagged_unused_owned_resources(self):
        self.record['network']['subnet']['owned'] = True
        self.network.list_subnets.return_value = response([])
        self.network.list_private_ips.return_value = response([])
        self.network.get_subnet.side_effect = [response(NS(id='ocid1.subnet.test', freeform_tags={m.TAG: self.record['launch_id']})), error('Not found', 404)]
        self.manager.cleanup(self.record, self.api)
        self.network.delete_subnet.assert_called_once()
        self.network.delete_vcn.assert_not_called()
        self.assertEqual(self.store.records()[0]['network']['subnet']['progress'], 'deleted')

    def test_cross_compartment_subnet_blocks_cleanup(self):
        self.record['network']['vcn']['owned'] = True
        self.identity.list_compartments.return_value = response([NS(id='ocid1.compartment.other', lifecycle_state='ACTIVE')])
        self.network.list_subnets.side_effect = [response([]), response([NS(id='ocid1.subnet.other', lifecycle_state='AVAILABLE')])]
        with self.assertRaisesRegex(m.Error, 'other subnets'):
            self.manager.cleanup(self.record, self.api)
        self.network.delete_vcn.assert_not_called()

    def test_fixed_security_launch_defaults(self):
        req = self.manager.request(self.cfg, self.record, 'ssh-ed25519 AAAA', 'AD-1', self.record['plugins'])
        self.assertTrue(req.is_pv_encryption_in_transit_enabled)
        self.assertTrue(req.instance_options.are_legacy_imds_endpoints_disabled)
        self.assertTrue(req.create_vnic_details.assign_public_ip)
        self.assertFalse(req.create_vnic_details.assign_ipv6_ip)
        self.assertIsNone(req.source_details.boot_volume_size_in_gbs)
        self.assertIsNone(req.source_details.kms_key_id)
        self.assertIsNone(req.availability_config.is_live_migration_preferred)
        self.assertEqual(req.availability_config.recovery_action, 'RESTORE_INSTANCE')
        self.assertNotIn('user_data', req.metadata)
        self.assertEqual(req.agent_config.plugins_config[1].desired_state, 'DISABLED')

    def test_pending_is_durable_before_api_call(self):
        def launch(request, **kwargs):
            saved = self.store.records()[0]
            self.assertEqual(saved['pending']['token'], kwargs['opc_retry_token'])
            self.assertEqual(saved['pending']['payload_hash'], m.digest(oci.util.to_dict(request)))
            raise TimeoutError()
        self.compute.launch_instance.side_effect = launch
        with self.assertRaises(m.Error):
            self.manager.launch(self.cfg)

    def test_generic_server_failure_never_falls_back(self):
        self.compute.launch_instance.side_effect = error('Unexpected server error')
        with self.assertRaisesRegex(m.Error, 'unresolved'):
            self.manager.launch(self.cfg)
        self.assertEqual(self.compute.launch_instance.call_count, 1)
        self.assertIn('pending', self.store.records()[0])

    def test_failed_guest_verification_keeps_created_id(self):
        record = dict(self.record, instance_id=instance().id, ubuntu_version='24.04', architecture='aarch64', ssh={'private_key': '/key', 'username': 'ubuntu'})
        self.compute.get_instance.return_value = response(instance())
        self.manager.addresses = Mock(return_value=[{'public_ipv4': '192.0.2.1', 'private_ipv4': '10.0.0.2'}])
        fd, filename = tempfile.mkstemp(dir=self.tmp.name)
        import os
        os.close(fd)
        self.manager.ssh_args = Mock(return_value=(['ssh'], filename))
        with patch.object(m.subprocess, 'run', return_value=NS(returncode=0, stdout='ID=ubuntu\nVERSION_ID="24.04"\nOCI_ARCH=x86_64\n')):
            with self.assertRaisesRegex(m.Error, 'Instance created:'):
                m.Manager.finish(self.manager, record, self.api)
        saved = self.store.records()[0]
        self.assertEqual(saved['instance_id'], instance().id)
        self.assertEqual(saved['progress'], 'ssh-verification-failed')
        self.assertFalse(Path(filename).exists())

    def test_guest_verification_accepts_oci_minimal_version_label(self):
        # Live OCI metadata uses this label; /etc/os-release reports only 24.04.
        record = dict(self.record, instance_id=instance().id, ubuntu_version='24.04 Minimal aarch64', architecture='aarch64', ssh={'private_key': '/key', 'username': 'ubuntu'})
        self.compute.get_instance.return_value = response(instance())
        self.manager.addresses = Mock(return_value=[{'public_ipv4': '192.0.2.1', 'private_ipv4': '10.0.0.2'}])
        filename = str(Path(self.tmp.name) / 'temporary-ssh-key')
        Path(filename).touch()
        self.manager.ssh_args = Mock(return_value=(['ssh'], filename))
        with patch.object(m.subprocess, 'run', return_value=NS(returncode=0, stdout='ID=ubuntu\nVERSION_ID="24.04"\nOCI_ARCH=aarch64\n')):
            m.Manager.finish(self.manager, record, self.api)
        saved = self.store.records()[0]
        self.assertEqual(saved['progress'], 'ssh-verified')
        self.assertEqual(saved['ubuntu_version'], '24.04')
        self.assertEqual(saved['verification']['architecture'], 'aarch64')
        self.assertFalse(Path(filename).exists())

    def test_temporary_ssh_copy_stays_outside_persistent_state(self):
        private = Path(self.tmp.name) / 'key'
        private.write_text('test key contents')
        record = dict(self.record, ssh={'private_key': str(private), 'username': 'ubuntu'})
        command, filename = self.manager.ssh_args(record, '192.0.2.1')
        self.addCleanup(lambda: Path(filename).unlink(missing_ok=True))
        self.assertNotEqual(Path(filename).parent, self.store.directory)
        self.assertEqual(Path(filename).stat().st_mode & 0o777, 0o600)

    def test_termination_requires_explicit_volume_choice(self):
        with self.assertRaises(SystemExit):
            m.parser().parse_args(['terminate', 'qbot'])
        for option, preserve in [('--preserve-boot-volume', True), ('--delete-boot-volume', False)]:
            args = m.parser().parse_args(['terminate', 'qbot', option])
            self.record['instance_id'] = instance().id
            self.store.save(self.record)
            self.compute.get_instance.side_effect = [response(instance()), response(instance(state='TERMINATED'))]
            self.compute.list_boot_volume_attachments.return_value = response([NS(boot_volume_id='ocid1.bootvolume.test')])
            self.manager.command(args)
            self.assertEqual(self.compute.terminate_instance.call_args.kwargs['preserve_boot_volume'], preserve)
            self.assertEqual(self.store.records()[0]['boot_volume_ids'], ['ocid1.bootvolume.test'])
            self.record.pop('termination', None)

    def test_network_create_ambiguity_keeps_token(self):
        self.record['network'] = {}
        self.network.list_vcns.__name__ = 'list_vcns'
        self.network.list_vcns.return_value = response([])
        self.network.create_vcn.side_effect = TimeoutError()
        details = oci.core.models.CreateVcnDetails(display_name='qbot-vcn', compartment_id=self.cfg['compartment_id'], cidr_block='10.0.0.0/16')
        for _ in range(2):
            with self.assertRaisesRegex(m.Error, 'conclusively'):
                self.manager.owned_network(self.cfg, self.api, self.record, 'vcn', details, self.network.list_vcns)
        calls = self.network.create_vcn.call_args_list
        self.assertEqual(calls[0].kwargs['opc_retry_token'], calls[1].kwargs['opc_retry_token'])

    def test_generated_key_pair_is_persistent_and_reused(self):
        with patch.object(m.subprocess, 'run', wraps=m.subprocess.run) as run:
            key = m.Manager.ssh_key(self.manager, self.cfg, self.record)
            private = Path(self.record['ssh']['private_key'])
            self.assertEqual(private.stat().st_mode & 0o777, 0o600)
            self.assertEqual(key, m.Manager.ssh_key(self.manager, self.cfg, self.record))
            self.assertEqual(sum(call.args[0][0:2] == ['ssh-keygen', '-q'] for call in run.call_args_list), 1)


class FreeTests(unittest.TestCase):
    def setUp(self):
        self.api = {k: Mock() for k in ('identity', 'compute', 'volume', 'limits')}
        sdk_list_names(*self.api.values())
        self.manager = m.Manager({'tenancy': 'ocid1.tenancy.root'}, Mock())
        self.cfg = {'mode': 'free-only', 'shape': 'VM.Standard.A1.Flex', 'region': 'us-chicago-1', 'compartment_id': 'ocid1.tenancy.root', 'ocpus': 2, 'memory_gbs': 8, 'network': {'existing': {}}}
        self.image = NS(compartment_id=None, size_in_mbs=47694)
        self.shapes = {'AD-1': NS(billing_type='LIMITED_FREE'), 'AD-2': NS(billing_type='LIMITED_FREE')}
        self.api['identity'].list_region_subscriptions.return_value = response([NS(region_name='us-chicago-1', is_home_region=True)])
        self.api['identity'].list_compartments.return_value = response([])
        self.api['identity'].list_availability_domains.return_value = response([NS(name='AD-1'), NS(name='AD-2')])
        self.api['compute'].list_instances.return_value = response([])
        self.api['volume'].list_volumes.return_value = response([])
        self.api['volume'].list_boot_volumes.return_value = response([])
        def definitions(compartment, service_name):
            names = ['standard-a1-core-count', 'standard-a1-memory-count', 'standard-a1-core-regional-count', 'standard-a1-memory-regional-count'] if service_name == 'compute' else ['total-storage-gb']
            return response([NS(name=n, scope_type='REGION' if 'regional' in n else 'AD') for n in names])
        self.api['limits'].list_limit_definitions.side_effect = definitions
        self.api['limits'].get_resource_availability.return_value = response(NS(available=200, used=0))

    def check(self):
        return self.manager.free_check(self.cfg, self.api, self.image, self.shapes)

    def test_wrong_home_region_rejected(self):
        self.cfg['region'] = 'us-phoenix-1'
        with self.assertRaisesRegex(m.Error, 'home region'):
            self.check()

    def test_paid_shape_requires_paid_mode(self):
        self.cfg['shape'] = 'VM.Standard.E5.Flex'
        with self.assertRaisesRegex(m.Error, 'paid must be explicit'):
            self.check()
        self.cfg['mode'] = 'paid'
        self.assertEqual(self.check(), self.shapes)

    def test_existing_a1_consumption_rejected(self):
        self.api['compute'].list_instances.return_value = response([instance()])
        with self.assertRaisesRegex(m.Error, '2 OCPUs / 12 GB'):
            self.check()

    def test_storage_combines_boot_and_block_volumes(self):
        self.api['volume'].list_volumes.return_value = response([NS(lifecycle_state='AVAILABLE', size_in_gbs=151)])
        with self.assertRaisesRegex(m.Error, '200 GB'):
            self.check()

    def test_unverified_service_limit_fails_closed(self):
        self.api['limits'].get_resource_availability.return_value = response(NS(available=None, used=None))
        with self.assertRaisesRegex(m.Error, 'usage is unavailable'):
            self.check()

    def test_ad_without_limits_skipped(self):
        def available(service, name, compartment, **kwargs):
            return response(NS(available=0 if kwargs.get('availability_domain') == 'AD-1' else 200, used=0))
        self.api['limits'].get_resource_availability.side_effect = available
        self.assertEqual(list(self.check()), ['AD-2'])

    def test_custom_ubuntu_image_is_not_assumed_free(self):
        self.image.compartment_id = 'ocid1.compartment.custom'
        with self.assertRaisesRegex(m.Error, 'platform Ubuntu'):
            self.check()

    def test_insufficient_compartment_visibility_fails_closed(self):
        self.api['identity'].list_compartments.side_effect = error('Forbidden', 403)
        with self.assertRaises(oci.exceptions.ServiceError):
            self.check()


class ConfigTests(unittest.TestCase):
    def test_documented_yaml_parses_without_host_dependencies(self):
        source = Path(__file__).resolve().parents[1] / 'config/oci-qbot.example.yml'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.yml'
            path.write_text(source.read_text().replace('ocid1.tenancy.oc1..REPLACE_WITH_QENDRO77_ROOT_OCID', 'ocid1.tenancy.oc1..localtest'))
            cfg = m.load_config(path)
            self.assertEqual((cfg['ocpus'], cfg['memory_gbs'], cfg['region']), (2, 8, 'us-chicago-1'))
            self.assertTrue(Path(cfg['ssh']['private_key']).is_absolute())

    def test_yaml_duplicate_keys_are_rejected(self):
        with self.assertRaisesRegex(m.Error, 'unique'):
            yaml.load('mode: free-only\nmode: paid\n', Loader=m.UniqueLoader)

    def test_container_audit_path_maps_to_host_root(self):
        self.assertEqual(m.host_path('/aws-deployment/output/key.pem'), m.ROOT / 'output/key.pem')

    def test_legacy_signing_key_path_is_mapped_before_sdk_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config'
            config.write_text('[DEFAULT]\ntenancy=ocid1.tenancy.test\nuser=ocid1.user.test\nfingerprint=00:11\nregion=us-chicago-1\nkey_file=/aws-deployment/output/oci-auth/key.pem\n')
            with patch.dict(m.os.environ, {'OCI_CONFIG_FILE': str(config), 'OCI_PROFILE': 'DEFAULT', 'OCI_SIGNING_KEY_FILE': ''}), patch.object(m.oci.config, 'validate_config') as validate:
                auth = m.auth_config()
                self.assertEqual(auth['key_file'], str(m.ROOT / 'output/oci-auth/key.pem'))
                validate.assert_called_once_with(auth)

    def test_state_is_private_and_configuration_secrets_are_not_saved(self):
        with tempfile.TemporaryDirectory() as directory:
            store = m.Store(directory)
            record = {'record_id': 'record', 'ssh': {'private_key': '/some/key'}}
            store.save(record)
            path = Path(directory) / 'record.json'
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), record)


if __name__ == '__main__':
    unittest.main()
