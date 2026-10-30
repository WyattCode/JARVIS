from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
cache = Path('/home/user/.local/state/jarvis-android-gradle/caches/modules-2/files-2.1')
def jar(module, version):
    return next((cache / module / version).rglob('*.jar'))
stdlib = jar('org.jetbrains.kotlin/kotlin-stdlib', '2.4.0')
annotations = jar('org.jetbrains/annotations', '13.0')
cp = [jar('org.jetbrains.kotlin/' + name, '2.4.0') for name in ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-script-runtime']]
cp += [jar('org.jetbrains.kotlin/kotlin-reflect', '1.6.10'), annotations, jar('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm', '1.8.0')]
java = '/home/user/.local/opt/jarvis-android-host/usr/lib/jvm/java-21-openjdk-arm64/bin/java'
out = Path('/home/user/.local/state/jarvis-035-review/native-levels');out.mkdir(parents=True, exist_ok=True)
subprocess.run([java, '-cp', ':'.join(map(str, cp)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', f'{stdlib}:{annotations}', '-d', str(out), str(root/'android/app/src/main/kotlin/ai/jarvis/app/android/PcmLevelTimeline.kt'), str(root/'tools/PcmLevelTimelineCheck.kt')], check=True)
subprocess.run([java, '-cp', f'{out}:{stdlib}', 'ai.jarvis.app.android.PcmLevelTimelineCheckKt'], check=True)
