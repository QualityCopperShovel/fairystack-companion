"""Exercise real child processes, including a never-ending command and lost owner."""
import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]

class CommandRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory()
        cls.library=str(Path(cls.tmp.name)/'runner.so')
        subprocess.run(['cc','-shared','-fPIC','-pthread','-I'+str(ROOT/'Sources/CommandRunner/include'),str(ROOT/'Sources/CommandRunner/CommandRunner.c'),'-o',cls.library],check=True,timeout=30)
        cls.lib=ctypes.CDLL(cls.library)
        cls.lib.fs_command_create.restype=ctypes.c_void_p
        cls.lib.fs_command_run.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_double]
        cls.lib.fs_command_cancel.argtypes=[ctypes.c_void_p]
        cls.lib.fs_command_destroy.argtypes=[ctypes.c_void_p]
        cls.lib.fs_command_output.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t]
        cls.lib.fs_command_output.restype=ctypes.c_size_t
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def run_job(self,command,seconds=2,cancel=False):
        handle=self.lib.fs_command_create()
        timer=threading.Timer(.15,lambda:self.lib.fs_command_cancel(handle)) if cancel else None
        if timer:timer.start()
        try:
            code=self.lib.fs_command_run(handle,command.encode(),self.tmp.name.encode(),seconds)
            buf=ctypes.create_string_buffer(131072)
            n=self.lib.fs_command_output(handle,buf,len(buf))
            return code,buf.raw[:n]
        finally:
            if timer:timer.join()
            self.lib.fs_command_destroy(handle)
    def test_success_failure_and_no_stdin(self):
        self.assertEqual(self.run_job('printf hello'),(0,b'hello'))
        self.assertEqual(self.run_job('exit 7')[0],7)
        self.assertEqual(self.run_job('cat')[0],0)
    def test_never_ending_child_times_out(self):
        began=time.monotonic();code,_=self.run_job('sleep 30',.3)
        # The watchdog may kill the child just before the owner observes deadline.
        self.assertIn(code,[-3,137]);self.assertLess(time.monotonic()-began,2)
    def test_cancel(self):self.assertEqual(self.run_job('sleep 30',cancel=True)[0],-2)
    def test_output_is_bounded(self):self.assertEqual(len(self.run_job('yes x',.3)[1]),131072)
    def test_children_cannot_outlive_command(self):
        marker=Path(self.tmp.name)/'escaped'
        self.run_job(f'(sleep 1; touch {marker}) & exit 0')
        time.sleep(1.2);self.assertFalse(marker.exists())
    def test_helper_crash_stops_group(self):
        marker=Path(self.tmp.name)/'orphan'
        script='''import ctypes,sys
l=ctypes.CDLL(sys.argv[1]);l.fs_command_create.restype=ctypes.c_void_p
l.fs_command_run.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_double]
l.fs_command_run(l.fs_command_create(),sys.argv[2].encode(),b'/tmp',20)
'''
        import sys
        child=subprocess.Popen([sys.executable,'-c',script,self.library,f'sleep 1; touch {marker}'])
        time.sleep(.25);child.kill();child.wait(timeout=2)
        time.sleep(1.2);self.assertFalse(marker.exists())

if __name__=='__main__':unittest.main()

