"""Exercise real Git state persistence using disposable local repositories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'cluster-state-sync.sh'

class RuntimeReportTest(unittest.TestCase):
    def git(self, directory, *args):
        return subprocess.check_output(['git','-C',str(directory),*args],text=True,stderr=subprocess.DEVNULL).strip()

    def run_persist(self, tracked=True, ignored=False, other_secret=False, outcome='success'):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); platform=root/'platform'; cluster=root/'cluster';remote=root/'remote.git'
            subprocess.run(['git','init','--bare','--quiet',str(remote)],check=True)
            for path in (platform,cluster):
                path.mkdir();self.git(path,'init','--quiet','-b','main')
                self.git(path,'config','user.name','Runtime test');self.git(path,'config','user.email','test@example.com');self.git(path,'config','commit.gpgsign','false')
                (path/'README.md').write_text('Fixture\n');self.git(path,'add','.');self.git(path,'commit','--quiet','-m','Initial fixture')
            self.git(cluster,'remote','add','origin',str(remote));self.git(cluster,'push','--quiet','-u','origin','main')
            (cluster/'out/root').mkdir(parents=True);(cluster/'secrets').mkdir()
            state=cluster/'out/root/terraform.tfstate';state.write_text('{}\n')
            report=cluster/'secrets/credentials_and_urls.md'
            if tracked:report.write_text('Old generated fixture\n')
            if ignored:(cluster/'.gitignore').write_text('secrets/credentials_and_urls.md\n')
            secret=cluster/'secrets/credentials.json';secret.write_text('{}\n')
            self.git(cluster,'add','.');self.git(cluster,'commit','--quiet','-m','Track runtime policy');self.git(cluster,'push','--quiet')
            before=self.git(cluster,'rev-parse','HEAD')
            state.write_text('{"serial": 1}\n');report.write_text('New generated fixture\n')
            if other_secret:secret.write_text('{"changed": true}\n')
            result=subprocess.run(['bash',str(SCRIPT),'persist','--platform-dir',str(platform),'--cluster-dir',str(cluster),'--deployment-id','test-1','--outcome',outcome],capture_output=True,text=True,env={**os.environ,'GIT_CONFIG_NOSYSTEM':'1'})
            after=self.git(cluster,'rev-parse','HEAD')
            changes=self.git(cluster,'diff','--name-only',before,after).splitlines()
            return result,changes,before==after

    def test_tracked_report_is_published_on_success_failure_and_destroy(self):
        for outcome in ('success','failed','destroyed'):
            with self.subTest(outcome=outcome):
                result,changes,_=self.run_persist(outcome=outcome)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(changes,['out/root/terraform.tfstate','secrets/credentials_and_urls.md'])

    def test_ignored_untracked_report_does_not_opt_in(self):
        result,changes,_=self.run_persist(tracked=False,ignored=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(changes,['out/root/terraform.tfstate'])

    def test_untracked_unignored_report_still_blocks(self):
        result,_,unchanged=self.run_persist(tracked=False)
        self.assertNotEqual(result.returncode,0);self.assertTrue(unchanged)

    def test_other_credentials_changes_still_block(self):
        result,_,unchanged=self.run_persist(other_secret=True)
        self.assertNotEqual(result.returncode,0);self.assertTrue(unchanged)

if __name__=='__main__':unittest.main()
