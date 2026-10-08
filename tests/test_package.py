import pathlib,subprocess,unittest,yaml
ROOT=pathlib.Path(__file__).resolve().parents[1]
class PackageTest(unittest.TestCase):
    def check(self, obj):
        return subprocess.run(['python3',str(ROOT/'scripts/check-manifest.py')],input=yaml.safe_dump(obj),text=True,capture_output=True)
    def test_refuses_infrastructure(self):
        for obj in [
            {'kind':'TargetGroupBinding','metadata':{'name':'craig-binding'}},
            {'kind':'Ingress','metadata':{'name':'craig-alb'},'spec':{'ingressClassName':'alb'}},
            {'kind':'PersistentVolumeClaim','metadata':{'name':'craig-data'}},
            {'kind':'Deployment','metadata':{'name':'nginx-controller'}},
            {'kind':'Service','metadata':{'name':'craig-public'},'spec':{'type':'LoadBalancer'}},
            {'kind':'Deployment','metadata':{'name':'craig-web','namespace':'default'}},
        ]:
            self.assertNotEqual(self.check(obj).returncode,0,obj)
    def test_org_render(self):
        rendered=subprocess.check_output(['helm','template','craig',str(ROOT/'deploy/kubernetes/craig'),'-n','craig-dev','-f',str(ROOT/'values-org.yaml')],text=True)
        docs=[x for x in yaml.safe_load_all(rendered) if x]
        for obj in docs:
            self.assertEqual(self.check(obj).returncode,0,obj['metadata']['name'])
        ingresses=[x for x in docs if x['kind']=='Ingress']
        self.assertEqual(len(ingresses),4)
        self.assertTrue(all(x['spec']['ingressClassName']=='nginx-craig-dev' for x in ingresses))
        self.assertFalse(any(x['metadata']['name']=='craig-local-gateway' for x in docs))
        self.assertTrue(any(x['kind']=='Deployment' and x['metadata']['name']=='mock-server' for x in docs))
if __name__=='__main__': unittest.main()
