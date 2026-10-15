#!/usr/bin/env python3
"""Stage-one OCI lifecycle management. Run through docker-oci.sh."""
import argparse
import configparser
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

import oci
import yaml

ROOT = Path(os.environ.get('OCI_HOST_ROOT', Path(__file__).resolve().parents[1]))
STATE = ROOT / 'output/oci'
TAG = 'dxnn-oci-launch'
NO_RETRY = oci.retry.NoneRetryStrategy()
TOKEN_LIFETIME = 23 * 3600  # Stop before Oracle's 24-hour expiry.


class Error(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def host_path(value, base=ROOT):
    value = str(value)
    if value.startswith('~/'):
        value = os.environ.get('OCI_HOST_HOME', str(Path.home())) + value[1:]
    # Earlier audit scripts used these container-only paths.
    if value.startswith('/aws-deployment/'):
        value = str(ROOT) + value[len('/aws-deployment'):]
    if value.startswith('/root/.ssh/') and os.environ.get('OCI_HOST_HOME'):
        value = os.environ['OCI_HOST_HOME'] + value[len('/root'):]
    path = Path(value)
    return path if path.is_absolute() else base / path


def auth_config():
    path = host_path(os.environ.get('OCI_CONFIG_FILE', '~/.oci/config'))
    profile = os.environ.get('OCI_PROFILE', 'DEFAULT')
    # from_file validates key paths before we can translate earlier container
    # paths. Parse the same INI/profile format, normalize first, then validate.
    parser = configparser.ConfigParser(interpolation=None)
    require(parser.read(path), f'OCI configuration file is missing: {path}')
    require(profile == 'DEFAULT' or parser.has_section(profile), 'OCI profile is missing.')
    cfg = dict(parser[profile])
    require(cfg.get('key_file') or os.environ.get('OCI_SIGNING_KEY_FILE'), 'OCI profile must reference a signing-key file.')
    cfg['key_file'] = str(host_path(os.environ.get('OCI_SIGNING_KEY_FILE') or cfg['key_file'], path.parent))
    # Only file-based signing is supported; never echo SDK config or key material.
    cfg.pop('key_content', None)
    oci.config.validate_config(cfg)
    return cfg


def all_data(call, *args, **kwargs):
    return oci.pagination.list_call_get_all_results(call, *args, **kwargs).data


def exact(items, predicate, description):
    matches = [x for x in items if predicate(x)]
    require(len(matches) == 1, f'{description}: expected exactly one match, found {len(matches)}.')
    return matches[0]


def fields(value, allowed, description):
    require(isinstance(value, dict), f'{description} must be a mapping.')
    require(not (set(value) - set(allowed)), f'Unsupported fields in {description}: {", ".join(sorted(set(value) - set(allowed)))}')


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    result = {}
    for key, value in node.value:
        name = loader.construct_object(key, deep=deep)
        require(isinstance(name, str) and name not in result, 'YAML keys must be unique strings.')
        result[name] = loader.construct_object(value, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def load_config(filename):
    path = host_path(filename)
    cfg = yaml.load(path.read_text(), Loader=UniqueLoader)
    fields(cfg, ('name', 'compartment_id', 'region', 'availability_domain', 'mode', 'image', 'shape', 'ocpus', 'memory_gbs', 'network', 'ssh', 'capacity_attempts_per_ad'), 'configuration')
    require(isinstance(cfg.get('name'), str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', cfg['name']), 'Invalid instance name.')
    require(isinstance(cfg.get('compartment_id'), str) and cfg['compartment_id'].startswith(('ocid1.tenancy.', 'ocid1.compartment.')) and 'REPLACE' not in cfg['compartment_id'], 'Supply a real compartment OCID (qendro77 root tenancy OCID for the example).')
    require(isinstance(cfg.get('region'), str) and cfg['region'] in oci.regions.REGIONS, 'Use a known OCI region identifier.')
    require(cfg.get('mode') in ('free-only', 'paid'), 'mode must explicitly be free-only or paid.')
    require(isinstance(cfg.get('shape'), str) and cfg['shape'].startswith('VM.'), 'Only VM shapes are supported.')
    for key in ('ocpus', 'memory_gbs'):
        require(type(cfg.get(key)) in (int, float) and math.isfinite(cfg[key]) and cfg[key] > 0, f'{key} must be a positive finite number.')
    tries = cfg.setdefault('capacity_attempts_per_ad', 1)
    require(type(tries) is int and 1 <= tries <= 3, 'capacity_attempts_per_ad must be 1..3.')
    if cfg.get('availability_domain') is not None:
        require(isinstance(cfg['availability_domain'], str) and bool(cfg['availability_domain']), 'Invalid AD preference.')
    fields(cfg.get('image'), ('id', 'display_name'), 'image')
    require(len(cfg['image']) == 1 and all(isinstance(x, str) and x for x in cfg['image'].values()), 'Select image by either OCID or exact display_name.')
    if 'id' in cfg['image']:
        require(cfg['image']['id'].startswith('ocid1.image.'), 'Invalid image OCID.')
    fields(cfg.get('network'), ('existing', 'create'), 'network')
    require(len(cfg['network']) == 1, 'Select exactly one network mode: existing or create.')
    net = next(iter(cfg['network'].values()))
    if 'existing' in cfg['network']:
        fields(net, ('subnet_id', 'vcn_name', 'subnet_name'), 'network.existing')
        require((set(net) == {'subnet_id'} and isinstance(net['subnet_id'], str) and net['subnet_id'].startswith('ocid1.subnet.')) or (set(net) == {'vcn_name', 'subnet_name'} and all(isinstance(v, str) and v for v in net.values())), 'Use subnet_id OR exact vcn_name and subnet_name.')
    else:
        fields(net, ('vcn_name', 'subnet_name', 'vcn_cidr', 'subnet_cidr', 'ssh_source_cidr'), 'network.create')
        require(set(net) == {'vcn_name', 'subnet_name', 'vcn_cidr', 'subnet_cidr', 'ssh_source_cidr'}, 'New network requires both names, both CIDRs, and ssh_source_cidr.')
        require(all(isinstance(v, str) and v for v in net.values()), 'New network values must be nonempty strings.')
        vcn, subnet, source = (ipaddress.IPv4Network(net[k]) for k in ('vcn_cidr', 'subnet_cidr', 'ssh_source_cidr'))
        require(vcn.is_private and subnet.subnet_of(vcn), 'Subnet must be inside a private IPv4 VCN CIDR.')
    fields(cfg.get('ssh'), ('username', 'public_key', 'private_key'), 'ssh')
    require(isinstance(cfg['ssh'].get('username'), str) and re.fullmatch(r'[a-z_][a-z0-9_-]*', cfg['ssh']['username']), 'Invalid SSH username.')
    require(bool(cfg['ssh'].get('public_key')) == bool(cfg['ssh'].get('private_key')), 'Supply both SSH key paths, or omit both to generate keys.')
    for key in ('public_key', 'private_key'):
        if key in cfg['ssh']:
            require(isinstance(cfg['ssh'][key], str) and cfg['ssh'][key], 'SSH key paths must be nonempty strings.')
            cfg['ssh'][key] = str(host_path(cfg['ssh'][key], path.parent))
    return cfg


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def ubuntu_release(value):
    # OCI image labels may include edition/architecture after the release.
    match = re.match(r'^(\d+\.\d+)(?:\s|$)', value)
    require(match, 'Ubuntu image version must start with a release number.')
    return match.group(1)


class Store:
    def __init__(self, directory=STATE):
        self.directory = Path(directory)

    @contextlib.contextmanager
    def lock(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / '.lock').open('a') as file:
            try:
                fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Error('Another OCI command is running. Try again after it finishes.')
            yield

    def records(self):
        return [json.loads(p.read_text()) for p in sorted(self.directory.glob('*.json'))]

    def save(self, record):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, filename = tempfile.mkstemp(dir=self.directory, suffix='.tmp')
        try:
            with os.fdopen(fd, 'w') as file:
                json.dump(record, file, indent=2)
                file.flush()
                os.fsync(file.fileno())
            os.replace(filename, self.directory / (record['record_id'] + '.json'))
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(filename):
                os.unlink(filename)

    def for_config(self, cfg):
        record_id = digest([cfg['region'], cfg['compartment_id'], cfg['name']])[:24]
        matches = [r for r in self.records() if r['record_id'] == record_id]
        if matches:
            record = matches[0]
            require(record['config_hash'] == digest(cfg), 'Configuration changed for an existing launch record. Restore the original configuration or choose a new name; inspect the recorded launch first.')
            return record
        record = {'record_id': record_id, 'launch_id': str(uuid.uuid4()), 'name': cfg['name'], 'region': cfg['region'], 'compartment_id': cfg['compartment_id'], 'config_hash': digest(cfg), 'progress': 'validated-config', 'network': {}, 'attempts': []}
        self.save(record)
        return record


def clients(cfg, region):
    cfg = dict(cfg, region=region)
    kwargs = dict(timeout=(10, 30), retry_strategy=NO_RETRY)
    return {
        'identity': oci.identity.IdentityClient(cfg, **kwargs),
        'compute': oci.core.ComputeClient(cfg, **kwargs),
        'network': oci.core.VirtualNetworkClient(cfg, **kwargs),
        'volume': oci.core.BlockstorageClient(cfg, **kwargs),
        'limits': oci.limits.LimitsClient(cfg, **kwargs),
        'agent': oci.compute_instance_agent.PluginconfigClient(cfg, **kwargs),
    }


def capacity_error(error):
    return isinstance(error, oci.exceptions.ServiceError) and error.status in (500, 503) and any(x in error.message.lower() for x in ('out of host capacity', 'out of capacity'))


class Manager:
    def __init__(self, auth, store, api=None):
        self.auth, self.store = auth, store
        self.api = api or (lambda region: clients(auth, region))

    def instances(self, api, compartment):
        return all_data(api['compute'].list_instances, compartment)

    def ads(self, api):
        return [x.name for x in all_data(api['identity'].list_availability_domains, self.auth['tenancy'])]

    def compartments(self, api):
        return [self.auth['tenancy']] + [x.id for x in all_data(api['identity'].list_compartments, self.auth['tenancy'], compartment_id_in_subtree=True, access_level='ANY') if x.lifecycle_state == 'ACTIVE']

    def image_shapes(self, cfg, api, ads):
        if 'id' in cfg['image']:
            image = api['compute'].get_image(cfg['image']['id']).data
        else:
            image = exact(all_data(api['compute'].list_images, cfg['compartment_id'], shape=cfg['shape']), lambda x: x.display_name == cfg['image']['display_name'], 'Image display name')
        require(image.lifecycle_state == 'AVAILABLE' and image.operating_system == 'Canonical Ubuntu', 'Image must be available Canonical Ubuntu.')
        shapes = {}
        for ad in ads:
            matches = [x for x in all_data(api['compute'].list_shapes, cfg['compartment_id'], availability_domain=ad, image_id=image.id) if x.shape == cfg['shape']]
            if not matches:
                continue
            shape = exact(matches, lambda x: True, 'Shape')
            if shape.is_flexible:
                cpu, mem = shape.ocpu_options, shape.memory_options
                require(cpu.min <= cfg['ocpus'] <= cpu.max and cfg['ocpus'] == int(cfg['ocpus']), 'OCPUs outside shape limits or not whole OCPUs.')
                require(mem.min_in_g_bs <= cfg['memory_gbs'] <= mem.max_in_g_bs and mem.min_per_ocpu_in_gbs <= cfg['memory_gbs'] / cfg['ocpus'] <= mem.max_per_ocpu_in_gbs, 'Memory outside shape limits.')
            else:
                require(shape.ocpus == cfg['ocpus'] and shape.memory_in_gbs == cfg['memory_gbs'], 'Fixed shape does not match configured CPU/memory.')
            shapes[ad] = shape
        require(shapes, 'No AD supports the requested image/shape combination.')
        return image, shapes

    def limit_check(self, api, service, name, cfg, ad, amount, definitions):
        definition = exact(definitions, lambda d: d.name == name, f'{service} limit {name}')
        kwargs = {'availability_domain': ad} if definition.scope_type == 'AD' else {}
        available = api['limits'].get_resource_availability(service, name, cfg['compartment_id'], **kwargs).data
        require(available.available is not None and available.available >= amount, f'Insufficient {service}/{name} availability in {ad}.')

    def free_check(self, cfg, api, image, shapes):
        if cfg['mode'] == 'paid':
            return shapes
        subscriptions = all_data(api['identity'].list_region_subscriptions, self.auth['tenancy'])
        require(any(x.region_name == cfg['region'] and x.is_home_region for x in subscriptions), 'free-only requires the tenancy home region.')
        require(cfg['shape'] in ('VM.Standard.A1.Flex', 'VM.Standard.E2.1.Micro'), 'Shape is not supported in free-only mode; paid must be explicit.')
        require(cfg['shape'] != 'VM.Standard.A1.Flex' or cfg['region'] != 'ap-chuncheon-1', 'Oracle excludes A1 Always Free eligibility in South Korea North (Chuncheon).')
        require(image.compartment_id is None and getattr(image, 'listing_type', None) is None, 'free-only accepts only Oracle platform Ubuntu images, not custom/marketplace images.')
        require(all(x.billing_type in ('ALWAYS_FREE', 'LIMITED_FREE') for x in shapes.values()), 'OCI does not advertise free eligibility for this image/shape.')
        # Enumerate ALL compartments; insufficient IAM visibility fails closed.
        compartments = self.compartments(api)
        instances, volumes = [], []
        ads = self.ads(api)
        for compartment in compartments:
            instances += [x for x in self.instances(api, compartment) if x.lifecycle_state != 'TERMINATED']
            volumes += [x for x in all_data(api['volume'].list_volumes, compartment_id=compartment) if x.lifecycle_state != 'TERMINATED']
            for ad in ads:
                volumes += [x for x in all_data(api['volume'].list_boot_volumes, availability_domain=ad, compartment_id=compartment) if x.lifecycle_state != 'TERMINATED']
        a1 = [x for x in instances if x.shape == 'VM.Standard.A1.Flex']
        if cfg['shape'] == 'VM.Standard.A1.Flex':
            require(sum(x.shape_config.ocpus for x in a1) + cfg['ocpus'] <= 2 and sum(x.shape_config.memory_in_gbs for x in a1) + cfg['memory_gbs'] <= 12, 'free-only exceeds the conservative current A1 allowance: 2 OCPUs / 12 GB across the home region.')
        else:
            require(sum(x.shape == cfg['shape'] for x in instances) < 2, 'free-only permits at most two E2.1.Micro instances.')
        # Default launch size is at least 50 GB and may be larger for this image.
        boot_gb = max(50, math.ceil(image.size_in_mbs / 1024))
        require(sum(x.size_in_gbs for x in volumes) + boot_gb <= 200, 'free-only exceeds 200 GB combined boot/block storage.')
        definitions = {service: all_data(api['limits'].list_limit_definitions, self.auth['tenancy'], service_name=service) for service in ('compute', 'block-storage')}
        compute_limits = [('standard-a1-core-count', cfg['ocpus']), ('standard-a1-memory-count', cfg['memory_gbs'])] if cfg['shape'] == 'VM.Standard.A1.Flex' else [('vm-standard-e2-1-micro-count', 1)]
        # Also enforce regional limits where OCI publishes them.
        if cfg['shape'] == 'VM.Standard.A1.Flex':
            for name, amount in [('standard-a1-core-regional-count', cfg['ocpus']), ('standard-a1-memory-regional-count', cfg['memory_gbs'])]:
                if any(d.name == name for d in definitions['compute']):
                    compute_limits.append((name, amount))
        storage_name = exact(definitions['block-storage'], lambda d: d.name in ('total-storage-gb', 'storage-total-gb'), 'Block storage GB limit').name
        # OCI also publishes free-storage limits. Enforce them whenever present,
        # rather than treating general paid-service capacity as free capacity.
        storage_limits = [storage_name] + [d.name for d in definitions['block-storage'] if d.name in ('total-free-storage-gb', 'total-free-storage-gb-regional')]
        if cfg['shape'] == 'VM.Standard.A1.Flex':
            # Root quota usage includes other A1 consumers (e.g. containers).
            # Sum AD usage once; stopped resources remain counted conservatively.
            for name, requested, cap in [('standard-a1-core-count', cfg['ocpus'], 2), ('standard-a1-memory-count', cfg['memory_gbs'], 12)]:
                usage = [api['limits'].get_resource_availability('compute', name, self.auth['tenancy'], availability_domain=ad).data.used for ad in ads]
                require(all(v is not None for v in usage) and sum(usage) + requested <= cap, 'free-only exceeds verified tenancy-wide A1 usage or usage is unavailable.')
        eligible = {}
        for ad, shape in shapes.items():
            try:
                for name, amount in compute_limits:
                    self.limit_check(api, 'compute', name, cfg, ad, amount, definitions['compute'])
                for name in storage_limits:
                    self.limit_check(api, 'block-storage', name, cfg, ad, boot_gb, definitions['block-storage'])
            except Error as error:
                print(f'Skipping {ad}: {error}', file=sys.stderr)
            else:
                eligible[ad] = shape
        require(eligible, 'No AD has sufficient verified free-only resource availability.')
        if 'create' in cfg['network']:
            netdefs = all_data(api['limits'].list_limit_definitions, self.auth['tenancy'], service_name='vcn')
            self.limit_check(api, 'vcn', 'vcn-count', cfg, ads[0], 1, netdefs)
        return eligible

    def ssh_key(self, cfg, record):
        paths = cfg['ssh']
        if 'private_key' in paths:
            private, public = Path(paths['private_key']), Path(paths['public_key'])
        else:
            directory = self.store.directory / 'keys'
            directory.mkdir(mode=0o700, exist_ok=True)
            private = directory / (record['record_id'] + '-ed25519')
            public = Path(str(private) + '.pub')
            if not private.exists():
                require(not public.exists(), 'Generated public key exists without its private key; inspect it before retrying.')
                subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(private)], check=True, capture_output=True)
        require(private.is_file() and public.is_file(), 'SSH public and private key files must both exist.')
        require(private.stat().st_mode & 0o077 == 0, 'SSH private key permissions must be 0600 or stricter.')
        text = public.read_text().strip()
        parts = text.split()
        require(len(text.splitlines()) == 1 and len(parts) >= 2 and parts[0] in ('ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'), 'Invalid SSH public key.')
        derived = subprocess.run(['ssh-keygen', '-y', '-P', '', '-f', str(private)], capture_output=True, text=True)
        require(derived.returncode == 0 and derived.stdout.split()[:2] == parts[:2], 'SSH key pair does not match or is encrypted (unattended verification needs an unencrypted key).')
        reference = {'private_key': str(private), 'public_key': str(public), 'username': paths['username'], 'fingerprint': digest(parts[:2])}
        require(not record.get('ssh') or record['ssh'] == reference, 'SSH key changed for a recorded launch.')
        record['ssh'] = reference
        self.store.save(record)
        return text

    def wait(self, get, resource_id, target, timeout=900):
        deadline = time.monotonic() + timeout
        while True:
            item = get(resource_id).data
            if item.lifecycle_state == target:
                return item
            require(item.lifecycle_state not in ('TERMINATED', 'FAILED') or target == 'TERMINATED', f'Resource entered {item.lifecycle_state}.')
            require(time.monotonic() < deadline, f'Timed out waiting for {resource_id} to reach {target}; its ID is retained.')
            time.sleep(5)

    def owned_network(self, cfg, api, record, kind, details, listing, **filters):
        resources = record['network']
        entry = resources.get(kind)
        if entry and entry.get('id'):
            return entry['id']
        matches = [x for x in all_data(listing, cfg['compartment_id'], **filters) if (x.freeform_tags or {}).get(TAG) == record['launch_id']]
        require(len(matches) <= 1, f'Multiple {kind} resources carry this launch tag; inspect before continuing.')
        if matches:
            item = matches[0]
        else:
            # Reject same-name unrecorded resources rather than duplicate or adopt.
            existing = all_data(listing, cfg['compartment_id'], **filters)
            require(not any(x.display_name == details.display_name and x.lifecycle_state != 'TERMINATED' for x in existing), f'{kind} name already exists; select existing network explicitly.')
            if entry:
                require(time.time() - entry['token_time'] < TOKEN_LIFETIME, f'Unresolved {kind} request has an expired retry token. Inspect OCI; do not remove the record to retry.')
            else:
                entry = {'owned': True, 'token': str(uuid.uuid4()), 'token_time': time.time(), 'progress': 'creating'}
                resources[kind] = entry
                self.store.save(record)
            details.freeform_tags = {TAG: record['launch_id']}
            try:
                item = getattr(api['network'], 'create_' + kind)(details, opc_retry_token=entry['token'], retry_strategy=NO_RETRY).data
            except Exception:
                raise Error(f'{kind} creation did not complete conclusively. State is retained; rerun the same launch to reconcile.') from None
        resources[kind] = dict(entry or {}, id=item.id, owned=True, progress='created')
        self.store.save(record)
        self.wait(getattr(api['network'], 'get_' + kind), item.id, 'AVAILABLE', 300)
        return item.id

    def network(self, cfg, api, record):
        n, models = api['network'], oci.core.models
        if 'existing' in cfg['network']:
            spec = cfg['network']['existing']
            if 'subnet_id' in spec:
                subnet = n.get_subnet(spec['subnet_id']).data
                vcn = n.get_vcn(subnet.vcn_id).data
            else:
                vcn = exact(all_data(n.list_vcns, cfg['compartment_id']), lambda x: x.display_name == spec['vcn_name'] and x.lifecycle_state == 'AVAILABLE', 'VCN name')
                subnet = exact(all_data(n.list_subnets, cfg['compartment_id'], vcn_id=vcn.id), lambda x: x.display_name == spec['subnet_name'] and x.lifecycle_state == 'AVAILABLE', 'Subnet name')
            record['network'] = {'vcn': {'id': vcn.id, 'owned': False}, 'subnet': {'id': subnet.id, 'owned': False}}
            self.store.save(record)
        else:
            spec = cfg['network']['create']
            vcn_id = self.owned_network(cfg, api, record, 'vcn', models.CreateVcnDetails(compartment_id=cfg['compartment_id'], display_name=spec['vcn_name'], cidr_block=spec['vcn_cidr'], is_ipv6_enabled=False), n.list_vcns)
            ig_id = self.owned_network(cfg, api, record, 'internet_gateway', models.CreateInternetGatewayDetails(compartment_id=cfg['compartment_id'], vcn_id=vcn_id, display_name=spec['vcn_name'] + '-internet', is_enabled=True), n.list_internet_gateways, vcn_id=vcn_id)
            rt_id = self.owned_network(cfg, api, record, 'route_table', models.CreateRouteTableDetails(compartment_id=cfg['compartment_id'], vcn_id=vcn_id, display_name=spec['subnet_name'] + '-routes', route_rules=[models.RouteRule(destination='0.0.0.0/0', destination_type='CIDR_BLOCK', network_entity_id=ig_id)]), n.list_route_tables, vcn_id=vcn_id)
            sl_id = self.owned_network(cfg, api, record, 'security_list', models.CreateSecurityListDetails(compartment_id=cfg['compartment_id'], vcn_id=vcn_id, display_name=spec['subnet_name'] + '-ssh', ingress_security_rules=[models.IngressSecurityRule(protocol='6', source=spec['ssh_source_cidr'], source_type='CIDR_BLOCK', is_stateless=False, tcp_options=models.TcpOptions(destination_port_range=models.PortRange(min=22, max=22)))], egress_security_rules=[models.EgressSecurityRule(protocol='all', destination='0.0.0.0/0', destination_type='CIDR_BLOCK', is_stateless=False)]), n.list_security_lists, vcn_id=vcn_id)
            subnet_id = self.owned_network(cfg, api, record, 'subnet', models.CreateSubnetDetails(compartment_id=cfg['compartment_id'], vcn_id=vcn_id, display_name=spec['subnet_name'], cidr_block=spec['subnet_cidr'], route_table_id=rt_id, security_list_ids=[sl_id], prohibit_public_ip_on_vnic=False), n.list_subnets, vcn_id=vcn_id)
            subnet = n.get_subnet(subnet_id).data
            vcn = n.get_vcn(vcn_id).data
        require(subnet.lifecycle_state == 'AVAILABLE' and vcn.lifecycle_state == 'AVAILABLE' and not subnet.prohibit_public_ip_on_vnic and not subnet.ipv6_cidr_blocks, 'Need an available public IPv4-only subnet/VCN.')
        require(subnet.compartment_id == cfg['compartment_id'], 'Subnet compartment does not match configuration.')
        route = n.get_route_table(subnet.route_table_id).data
        public_routes = [r for r in route.route_rules if r.destination == '0.0.0.0/0' and r.network_entity_id.startswith('ocid1.internetgateway.')]
        require(public_routes, 'Subnet has no IPv4 default route to an internet gateway.')
        require(any(n.get_internet_gateway(r.network_entity_id).data.is_enabled for r in public_routes), 'Internet gateway is disabled.')
        ingress, egress = [], []
        for sid in subnet.security_list_ids:
            sl = n.get_security_list(sid).data
            ingress += sl.ingress_security_rules
            egress += sl.egress_security_rules
        def permits_ssh(rule):
            return rule.source_type == 'CIDR_BLOCK' and rule.protocol in ('all', '6') and (not rule.tcp_options or not rule.tcp_options.destination_port_range or rule.tcp_options.destination_port_range.min <= 22 <= rule.tcp_options.destination_port_range.max)
        require(any(permits_ssh(r) for r in ingress), 'Subnet security lists do not permit SSH; reused networks are never modified.')
        require(any(r.protocol == 'all' and r.destination == '0.0.0.0/0' for r in egress), 'Subnet must permit outbound IPv4 traffic.')
        if 'existing' in cfg['network']:
            record['network']['route_table'] = {'id': subnet.route_table_id, 'owned': False}
            for index, sid in enumerate(subnet.security_list_ids):
                record['network'][f'security_list_{index}'] = {'id': sid, 'owned': False}
            for index, route in enumerate(public_routes):
                record['network'][f'internet_gateway_{index}'] = {'id': route.network_entity_id, 'owned': False}
            self.store.save(record)
        return subnet

    def request(self, cfg, record, key, ad, plugins):
        m = oci.core.models
        return m.LaunchInstanceDetails(
            compartment_id=cfg['compartment_id'], display_name=cfg['name'], availability_domain=ad,
            shape=cfg['shape'], shape_config=m.LaunchInstanceShapeConfigDetails(ocpus=cfg['ocpus'], memory_in_gbs=cfg['memory_gbs']) if cfg['shape'].endswith('.Flex') else None,
            source_details=m.InstanceSourceViaImageDetails(image_id=record['image_id']),
            create_vnic_details=m.CreateVnicDetails(subnet_id=record['network']['subnet']['id'], assign_public_ip=True, assign_ipv6_ip=False),
            metadata={'ssh_authorized_keys': key}, freeform_tags={TAG: record['launch_id']},
            is_pv_encryption_in_transit_enabled=True,
            instance_options=m.InstanceOptions(are_legacy_imds_endpoints_disabled=True),
            availability_config=m.LaunchInstanceAvailabilityConfigDetails(recovery_action='RESTORE_INSTANCE'),
            agent_config=m.LaunchInstanceAgentConfigDetails(is_monitoring_disabled=False, is_management_disabled=False, are_all_plugins_disabled=False, plugins_config=[m.InstanceAgentPluginConfigDetails(name=p, desired_state='ENABLED' if p == 'Compute Instance Monitoring' else 'DISABLED') for p in plugins]))

    def reconcile(self, record, api):
        matches = [i for i in self.instances(api, record['compartment_id']) if (i.freeform_tags or {}).get(TAG) == record['launch_id']]
        require(len(matches) <= 1, 'Multiple instances carry this launch tag; inspect OCI before continuing.')
        if matches:
            self.created(record, matches[0])
            return True
        return False

    def created(self, record, instance):
        record.update(instance_id=instance.id, availability_domain=instance.availability_domain, progress='instance-created')
        record.pop('pending', None)
        self.store.save(record)
        print(f'Instance created/recorded: {instance.id}', flush=True)

    def launch(self, cfg):
        record = self.store.for_config(cfg)
        api = self.api(cfg['region'])
        if record.get('instance_id'):
            return self.finish(record, api)
        key = self.ssh_key(cfg, record)
        if self.reconcile(record, api):
            return self.finish(record, api)
        if record.get('pending'):
            # Replay only the same immutable payload, AD and token. No fallback
            # from ambiguous results, including timeouts and generic 5xx errors.
            if self.send(cfg, record, api, key, record['pending']):
                return self.finish(record, api)
        active = [i for i in self.instances(api, cfg['compartment_id']) if i.display_name == cfg['name'] and i.lifecycle_state != 'TERMINATED']
        require(not active, 'An unrecorded instance already uses this name. Inspect it by OCID; refusing to launch a duplicate.')
        ads = self.ads(api)
        if cfg.get('availability_domain'):
            require(cfg['availability_domain'] in ads, 'AD preference is not in this tenancy/region.')
            ads.remove(cfg['availability_domain'])
            ads.insert(0, cfg['availability_domain'])
        image, shapes = self.image_shapes(cfg, api, ads)
        # Freeze image selection, plugin configuration and expected guest details.
        if record.get('image_id'):
            require(record['image_id'] == image.id, 'Image resolution changed for recorded launch.')
        record.update(image_id=image.id, ubuntu_version=ubuntu_release(image.operating_system_version),
                      architecture='aarch64' if 'aarch64' in image.display_name.lower() or 'arm' in next(iter(shapes.values())).processor_description.lower() or 'ampere' in next(iter(shapes.values())).processor_description.lower() else 'x86_64')
        shapes = self.free_check(cfg, api, image, shapes)
        subnet = self.network(cfg, api, record)
        ads = [ad for ad in ads if ad in shapes and (not subnet.availability_domain or subnet.availability_domain == ad)]
        require(ads, 'Subnet AD is incompatible with eligible compute ADs.')
        if 'plugins' not in record:
            record['plugins'] = [p.name for p in all_data(api['agent'].list_instanceagent_available_plugins, cfg['compartment_id'], image.operating_system, image.operating_system_version) if p.is_supported]
        self.store.save(record)
        for _ in range(cfg['capacity_attempts_per_ad']):
            for ad in ads:
                pending = {'ad': ad, 'token': str(uuid.uuid4()), 'token_time': time.time()}
                if self.send(cfg, record, api, key, pending):
                    return self.finish(record, api)
        record['progress'] = 'capacity-exhausted'
        self.store.save(record)
        raise Error(f'Out of host capacity in all eligible ADs after {cfg["capacity_attempts_per_ad"]} attempt(s) per AD. No VM was created; rerun later with the same configuration.')

    def send(self, cfg, record, api, key, pending):
        require(time.time() - pending['token_time'] < TOKEN_LIFETIME, 'Unresolved launch token is too old to replay safely. Inspect OCI by launch tag/OCID; do not discard state or create a new token.')
        request = self.request(cfg, record, key, pending['ad'], record['plugins'])
        payload_hash = digest(oci.util.to_dict(request))
        require(not pending.get('payload_hash') or pending['payload_hash'] == payload_hash, 'Pending launch payload changed; refusing to reuse its retry token.')
        pending['payload_hash'] = payload_hash
        record.update(pending=pending, progress='launch-request-pending')
        self.store.save(record)
        print(f'Launching {cfg["name"]} in {pending["ad"]} ({cfg["mode"]})...', flush=True)
        try:
            instance = api['compute'].launch_instance(request, opc_retry_token=pending['token'], retry_strategy=NO_RETRY).data
        except Exception as error:
            if capacity_error(error):
                record['attempts'].append({'ad': pending['ad'], 'outcome': 'capacity', 'time': time.time(), 'request_id': error.request_id})
                record.pop('pending', None)
                record['progress'] = 'capacity-unavailable'
                self.store.save(record)
                return False
            record['progress'] = 'launch-outcome-unresolved'
            self.store.save(record)
            raise Error('Launch outcome is unresolved or rejected. Rerun the same configuration to reconcile/replay the saved token; no alternate AD was attempted. OCI status/code: ' + str(getattr(error, 'status', 'connection failure')) + '/' + str(getattr(error, 'code', 'unknown')) + '; request ID: ' + str(getattr(error, 'request_id', 'unavailable'))) from None
        self.created(record, instance)
        return True

    def addresses(self, api, instance):
        attachments = all_data(api['compute'].list_vnic_attachments, compartment_id=instance.compartment_id, instance_id=instance.id)
        vnics = [api['network'].get_vnic(a.vnic_id).data for a in attachments if a.lifecycle_state == 'ATTACHED']
        return [{'private_ipv4': v.private_ip, 'public_ipv4': v.public_ip} for v in vnics]

    def ssh_args(self, record, address, verify=False):
        require(record and record.get('ssh'), 'SSH needs a recorded key reference; launch records are in output/oci/.')
        key = Path(record['ssh']['private_key'])
        require(key.is_file(), 'Recorded SSH private key is missing.')
        # OpenSSH may reject mounted keys based on container filesystem metadata.
        # Use a temporary 0600 copy, deleted immediately after SSH exits.
        fd, filename = tempfile.mkstemp(prefix='oci-ssh-', suffix='.key')
        with os.fdopen(fd, 'wb') as file:
            file.write(key.read_bytes())
        args = ['ssh', '-i', filename, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', f'UserKnownHostsFile={self.store.directory / "known_hosts"}', '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1']
        if verify:
            args += ['-o', 'BatchMode=yes']
        args += [record['ssh']['username'] + '@' + str(ipaddress.IPv4Address(address))]
        return args, filename

    def finish(self, record, api):
        instance = self.wait(api['compute'].get_instance, record['instance_id'], 'RUNNING')
        addresses = self.addresses(api, instance)
        record.update(progress='running', addresses=addresses)
        self.store.save(record)
        address = next((a['public_ipv4'] for a in addresses if a['public_ipv4']), None)
        if not address:
            record['progress'] = 'ssh-verification-failed'
            self.store.save(record)
            raise Error(f'Instance created: {instance.id}, but no public IPv4 is available. Rerun launch to verify this instance.')
        args, filename = self.ssh_args(record, address, verify=True)
        command = 'cat /etc/os-release; printf "\\nOCI_ARCH="; uname -m'
        deadline = time.monotonic() + 300
        try:
            while True:
                result = subprocess.run(args + [command], capture_output=True, text=True, timeout=30)
                if result.returncode == 0:
                    values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
                    expected_version = ubuntu_release(record['ubuntu_version'])
                    valid = values.get('ID', '').strip('"') == 'ubuntu' and values.get('VERSION_ID', '').strip('"') == expected_version and values.get('OCI_ARCH') == record['architecture']
                    if valid:
                        record.update(progress='ssh-verified', ubuntu_version=expected_version, verification={'ubuntu_version': expected_version, 'architecture': record['architecture']})
                        self.store.save(record)
                        print(f'RUNNING {instance.id} public IPv4={address}; SSH verified Ubuntu {record["ubuntu_version"]} {record["architecture"]}.')
                        return
                    break
                if time.monotonic() >= deadline:
                    break
                time.sleep(5)
        except (subprocess.TimeoutExpired, OSError):
            pass
        finally:
            os.unlink(filename)
        record['progress'] = 'ssh-verification-failed'
        self.store.save(record)
        raise Error(f'Instance created: {instance.id} ({address}), but SSH/Ubuntu/architecture verification failed. Rerun launch to verify the same instance; no new VM will be created.')

    def resolve(self, target, region=None):
        records = self.store.records()
        matches = [r for r in records if (r.get('instance_id') == target if target.startswith('ocid1.instance.') else r['name'] == target) and (not region or r['region'] == region)]
        require(len(matches) <= 1, 'Ambiguous recorded instance name/OCID; use an explicit OCID and --region.')
        record = matches[0] if matches else None
        if not target.startswith('ocid1.instance.'):
            require(record and record.get('instance_id'), 'Name has no recorded instance OCID. Use launch to reconcile a pending request, or supply an explicit OCID.')
        instance_id = target if target.startswith('ocid1.instance.') else record['instance_id']
        api = self.api(region or (record['region'] if record else self.auth['region']))
        instance = api['compute'].get_instance(instance_id).data
        return record, api, instance

    def status(self, instance, api):
        print(json.dumps({'instance_id': instance.id, 'name': instance.display_name, 'state': instance.lifecycle_state, 'ad': instance.availability_domain, 'addresses': self.addresses(api, instance)}, indent=2))

    def cleanup(self, record, api):
        resources, n = record['network'], api['network']
        owned = {k: v for k, v in resources.items() if v.get('owned') and v.get('id') and v.get('progress') != 'deleted'}
        if not owned:
            print('Reused network preserved; no owned network resources to delete.')
            return
        vcn_id = resources.get('vcn', {}).get('id')
        # Refuse cleanup if any additional subnet uses this VCN. OCI deletion
        # also enforces dependencies; never update somebody else's attachments.
        # Resources sharing the VCN may live in a different compartment.
        compartments = self.compartments(api)
        subnets = [s for cid in compartments for s in all_data(n.list_subnets, cid, vcn_id=vcn_id)]
        subnet_id = resources.get('subnet', {}).get('id')
        require(not any(s.id != subnet_id and s.lifecycle_state != 'TERMINATED' for s in subnets), 'Owned VCN has other subnets; network preserved because it is in use.')
        for kind in ('subnet', 'route_table', 'security_list', 'internet_gateway', 'vcn'):
            entry = owned.get(kind)
            if not entry:
                continue
            try:
                item = getattr(n, 'get_' + kind)(entry['id']).data
            except oci.exceptions.ServiceError as error:
                if error.status == 404:
                    entry['progress'] = 'deleted'
                    self.store.save(record)
                    continue
                raise
            require((item.freeform_tags or {}).get(TAG) == record['launch_id'], f'Ownership tag missing for {kind}; refusing deletion.')
            if kind == 'subnet':
                require(not all_data(n.list_private_ips, subnet_id=item.id), 'Subnet still has private IPs; network preserved because it is in use.')
            if kind == 'internet_gateway':
                routes = [table for cid in compartments for table in all_data(n.list_route_tables, cid, vcn_id=vcn_id)]
                require(not any(r.network_entity_id == item.id for table in routes for r in table.route_rules), 'Internet gateway still has route references; preserved because it is in use.')
            getattr(n, 'delete_' + kind)(item.id, retry_strategy=NO_RETRY)
            # Deletions are asynchronous; wait for 404 before deleting parents.
            deadline = time.monotonic() + 300
            while True:
                try:
                    current = getattr(n, 'get_' + kind)(item.id).data
                    if current.lifecycle_state == 'TERMINATED':
                        break
                except oci.exceptions.ServiceError as error:
                    if error.status == 404:
                        break
                    raise
                require(time.monotonic() < deadline, f'Timed out deleting {kind}; rerun termination with --cleanup-network.')
                time.sleep(3)
            entry['progress'] = 'deleted'
            self.store.save(record)
        print('Owned, unused network resources deleted.')

    def command(self, args):
        if args.command == 'launch':
            return self.launch(load_config(args.config))
        if args.command == 'list':
            records = self.store.records()
            if not records:
                print('No OCI instance records in output/oci/.')
            for record in records:
                if record.get('instance_id'):
                    _, api, instance = self.resolve(record['instance_id'], record['region'])
                    self.status(instance, api)
                else:
                    print(json.dumps({k: record[k] for k in ('name', 'region', 'progress', 'launch_id')}))
            return
        record, api, instance = self.resolve(args.instance, args.region)
        compute = api['compute']
        if args.command == 'status':
            return self.status(instance, api)
        if args.command == 'ssh':
            require(instance.lifecycle_state == 'RUNNING', 'SSH requires a RUNNING instance.')
            addresses = self.addresses(api, instance)
            address = next((a['public_ipv4'] for a in addresses if a['public_ipv4']), None)
            require(address, 'Instance has no public IPv4.')
            command, filename = self.ssh_args(record, address)
            try:
                return subprocess.call(command)
            finally:
                os.unlink(filename)
        if args.command == 'terminate':
            preserve = args.preserve_boot_volume
            require(not args.cleanup_network or record, 'No ownership record; network cleanup is unavailable for this OCID.')
            print('Termination will ' + ('PRESERVE the boot volume; storage allocation/billing continues.' if preserve else 'DELETE the boot volume and its data permanently.'), flush=True)
            if record:
                if instance.lifecycle_state != 'TERMINATED':
                    record['boot_volume_ids'] = [a.boot_volume_id for a in all_data(compute.list_boot_volume_attachments, availability_domain=instance.availability_domain, compartment_id=instance.compartment_id, instance_id=instance.id)]
                require(not record.get('termination') or record['termination']['preserve_boot_volume'] == preserve, 'Termination storage choice differs from the recorded request.')
                record.update(progress='termination-requested', termination={'preserve_boot_volume': preserve})
                self.store.save(record)
            if instance.lifecycle_state != 'TERMINATED':
                compute.terminate_instance(instance.id, preserve_boot_volume=preserve, retry_strategy=NO_RETRY)
                self.wait(compute.get_instance, instance.id, 'TERMINATED')
            if record:
                record['progress'] = 'terminated'
                self.store.save(record)
            if args.cleanup_network:
                require(record, 'No ownership record; network cleanup is unavailable for this OCID.')
                self.cleanup(record, api)
            return
        action, target = {'start': ('START', 'RUNNING'), 'stop': ('SOFTSTOP', 'STOPPED'), 'reboot': ('SOFTRESET', 'RUNNING')}[args.command]
        require(instance.lifecycle_state in ('RUNNING', 'STOPPED'), 'Instance is transitioning or terminated; inspect status before requesting an action.')
        if args.command == 'reboot':
            require(instance.lifecycle_state == 'RUNNING', 'Reboot requires a RUNNING instance.')
        if record:
            record['progress'] = args.command + '-requested'
            self.store.save(record)
        if args.command == 'reboot' or instance.lifecycle_state != target:
            compute.instance_action(instance.id, action, retry_strategy=NO_RETRY)
        instance = self.wait(compute.get_instance, instance.id, target)
        if record:
            record['progress'] = target.lower()
            self.store.save(record)
        self.status(instance, api)


def parser():
    p = argparse.ArgumentParser(description='Clean Ubuntu OCI VMs, using Docker; no AWS credentials required.')
    p.add_argument('--mount-plan', action='store_true', help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest='command', required=True)
    launch = sub.add_parser('launch', help='Launch or resume the same YAML-configured instance')
    launch.add_argument('-c', '--config', required=True)
    sub.add_parser('list', help='List recorded instances with current OCI status/IPs')
    for cmd in ('status', 'ssh', 'start', 'stop', 'reboot', 'terminate'):
        command = sub.add_parser(cmd)
        command.add_argument('instance', help='Explicit OCID or unambiguous recorded name')
        command.add_argument('--region', help='Region for an unrecorded explicit OCID (default: OCI profile region)')
        if cmd == 'terminate':
            group = command.add_mutually_exclusive_group(required=True)
            group.add_argument('--preserve-boot-volume', action='store_true')
            group.add_argument('--delete-boot-volume', action='store_true')
            command.add_argument('--cleanup-network', action='store_true', help='Delete only recorded, owned, unused network resources')
    return p


def mount_plan(args):
    paths = set()
    auth = host_path(os.environ.get('OCI_CONFIG_FILE', '~/.oci/config'))
    if auth.is_file():
        config = configparser.ConfigParser(interpolation=None)
        config.read(auth)
        profile = os.environ.get('OCI_PROFILE', 'DEFAULT')
        require(profile == 'DEFAULT' or config.has_section(profile), 'OCI profile is missing.')
        key = os.environ.get('OCI_SIGNING_KEY_FILE') or config[profile].get('key_file')
        if key:
            paths.add(str(host_path(key, auth.parent)))
    if args.command == 'launch':
        # Planning also reads configs outside the repo; the wrapper must expose
        # their containing directory before this pass (see docker-oci.sh).
        cfg = load_config(args.config)
        paths.update(cfg['ssh'][k] for k in ('private_key', 'public_key') if k in cfg['ssh'])
    elif args.command == 'ssh':
        for record in Store().records():
            if record['name'] == args.instance or record.get('instance_id') == args.instance:
                if record.get('ssh'):
                    paths.add(record['ssh']['private_key'])
    for path in sorted(paths):
        sys.stdout.buffer.write(path.encode() + b'\0')


def main():
    os.umask(0o077)
    args = parser().parse_args()
    try:
        if args.mount_plan:
            mount_plan(args)
            return 0
        store = Store()
        with store.lock():
            return Manager(auth_config(), store).command(args) or 0
    except oci.exceptions.ServiceError as error:
        print(f'OCI request failed: HTTP {error.status}, code={error.code}, request ID={error.request_id}. No SDK credential/config dump is emitted.', file=sys.stderr)
    except (Error, OSError, ValueError, yaml.YAMLError, configparser.Error, oci.exceptions.ConfigFileNotFound, oci.exceptions.ProfileNotFound, oci.exceptions.InvalidConfig, subprocess.CalledProcessError) as error:
        print(f'Error: {error}', file=sys.stderr)
    except oci.exceptions.RequestException:
        print('OCI connection failed; saved launch progress is retained.', file=sys.stderr)
    except Exception as error:
        # Unknown SDK/auth failures must not dump configs or private keys.
        print(f'Operation failed ({type(error).__name__}); saved progress is retained.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
