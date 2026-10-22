"""Exercise the patched engine's acquire branch, not a reimplementation.
Pass a directory containing pristine pinned dependency sources (see documentation).
"""
import hashlib,json,pathlib,subprocess,sys,tempfile,unittest,shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCES=pathlib.Path(sys.argv.pop()) if len(sys.argv)>1 else None
class Patches(unittest.TestCase):
 def test_pinned_engine_patch_and_transient_acquire(self):
  self.assertIsNotNone(SOURCES,'Pass the pinned source fixture directory')
  with tempfile.TemporaryDirectory() as temporary:
   tree=pathlib.Path(temporary)
   manifest=json.loads((ROOT/'helios/compatibility/proton-ge.lock.json').read_text())
   for patch in manifest['patches']:
    source=ROOT/'helios/compatibility'/patch['file']
    self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),patch['sha256'])
    target=tree/patch['component'];shutil.copytree(SOURCES/patch['component'],target)
    subprocess.run(['git','-C',str(target),'apply','--check',str(source)],check=True)
    subprocess.run(['git','-C',str(target),'apply',str(source)],check=True)
   code=(tree/'dxvk-helios/src/dxvk/dxvk_presenter.cpp').read_text()
   branch=code[code.index('    // Don\'t acquire if'):code.index('    // Update HDR metadata')]
   harness=r'''
#include <cassert>
#include <cstdint>
#include <limits>
#include <vector>
using VkResult=int;
constexpr int VK_SUCCESS=0,VK_NOT_READY=1,VK_TIMEOUT=2,VK_NULL_HANDLE=0;
struct PresenterSync { int acquire=1;bool fenceSignaled=true; };
struct Logger { template<class T> static void info(T){} };
namespace str { template<class... T> int format(T...){return 0;} }
struct Mock {
 int result=VK_SUCCESS;int device(){return 0;}
 int vkAcquireNextImageKHR(int,int,uint64_t,int,int,unsigned*){return result;}
};
struct Presenter {
 int m_acquireStatus=VK_NOT_READY,m_swapchain=1,m_frameIndex=0,recreates=0;
 unsigned m_imageIndex=0;Mock mock;Mock* m_vkd=&mock;
 std::vector<PresenterSync> m_semaphores{PresenterSync{}};
 void waitForSwapchainFence(PresenterSync& s){s.fenceSignaled=false;}
 int recreateSwapChain(){++recreates;m_swapchain=1;return VK_SUCCESS;}
 int softError(int r){return r;}
 int acquire(){bool hasSwapchain=m_swapchain!=0;
'''+branch+r'''
 return VK_SUCCESS;
 }
};
int main(){
 for(int transient:{VK_NOT_READY,VK_TIMEOUT}){
  Presenter p;p.mock.result=transient;
  assert(p.acquire()==VK_NOT_READY);assert(p.recreates==0);
  assert(!p.m_semaphores[0].fenceSignaled);
  p.mock.result=VK_SUCCESS;assert(p.acquire()==VK_SUCCESS);assert(p.recreates==0);
  Presenter fresh;fresh.m_swapchain=0;fresh.mock.result=transient;
  assert(fresh.acquire()==VK_NOT_READY);assert(fresh.recreates==1);
  fresh.mock.result=VK_SUCCESS;assert(fresh.acquire()==VK_SUCCESS);assert(fresh.recreates==1);
 }
 Presenter lost;lost.m_acquireStatus=-100;assert(lost.acquire()==VK_SUCCESS);assert(lost.recreates==1);
 Presenter failed;failed.m_swapchain=0;failed.mock.result=-4;assert(failed.acquire()==-4);
}
'''
   cpp=tree/'acquire.cpp';cpp.write_text(harness)
   subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(cpp),'-o',str(tree/'test')],check=True)
   subprocess.run([str(tree/'test')],check=True)
if __name__=='__main__':unittest.main()
