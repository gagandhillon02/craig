#!/usr/bin/env python3
"""Reject infrastructure ownership in an application release before reset."""
import sys
import yaml
allowed = {'Deployment', 'StatefulSet', 'Service', 'ConfigMap', 'Secret', 'Ingress', 'Job', 'ServiceAccount', 'PersistentVolumeClaim'}
for obj in yaml.safe_load_all(sys.stdin):
    if not obj:
        continue
    kind = obj.get('kind')
    name = obj.get('metadata', {}).get('name', '')
    namespace = obj.get('metadata', {}).get('namespace', 'craig-dev')
    if namespace != 'craig-dev':
        raise SystemExit(f'REFUSED: resource outside craig-dev: {kind}/{name}')
    spec = obj.get('spec', {})
    annotations = obj.get('metadata', {}).get('annotations', {})
    if kind not in allowed or 'nginx' in name or not (name.startswith('craig-') or name in {'mock-server', 'craig'}):
        raise SystemExit(f'REFUSED: unexpected release resource {kind}/{name}; review ownership before reset')
    if kind == 'Ingress' and (spec.get('ingressClassName') == 'alb' or any(k.startswith('alb.ingress.kubernetes.io/') for k in annotations) or annotations.get('kubernetes.io/ingress.class') == 'alb'):
        raise SystemExit(f'REFUSED: release owns ALB ingress {name}')
    if kind == 'Service' and spec.get('type', 'ClusterIP') != 'ClusterIP':
        raise SystemExit(f'REFUSED: release owns externally exposed service {name}')
    if kind == 'PersistentVolumeClaim':
        raise SystemExit(f'REFUSED: release owns PVC {name}; preserve it before resetting')
print('Release contains application resources only.', file=sys.stderr)
