#!/usr/bin/env python3
"""Build/inspect actual SDK artifacts and run the host's native exports. No App ID."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import shutil
import sys
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tests/steam'))
from support import LOCK, SDK, STEAM_LOCK, check_engine, extract, run, stage_sdk, verify, register_extensions
HERE = Path(__file__).resolve().parent


def preset(name, target, template, debug, steam):
    platform_name = {'linux': 'Linux', 'windows': 'Windows Desktop', 'web': 'Web'}[target]
    features = 'steam' if steam else ''
    label = f'{target}-{debug}' + ('-feature' if steam else '')
    output = f'[preset.{name}]\nname="{label}"\nplatform="{platform_name}"\nrunnable=true\ncustom_features="{features}"\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nscript_export_mode=0\n'
    output += f'[preset.{name}.options]\ncustom_template/debug="{template.as_posix()}"\ncustom_template/release="{template.as_posix()}"\n'
    if target == 'web':
        output += 'variant/extensions_support=false\nvariant/thread_support=false\nhtml/export_icon=false\n'
    else:
        output += 'binary_format/architecture="x86_64"\nbinary_format/embed_pck=false\n'
        if target == 'windows':
            output += 'application/modify_resources=false\ndebug/export_console_wrapper=2\n'
    return output


def inspect_package(godot, inspector, artifact, target, steam, native_sources, logs):
    output = run([godot, '--headless', '--path', inspector, '--script', 'inspect.gd', '--',
                  '--pack=' + str(artifact.with_suffix('.pck'))], inspector,
                 'PACK_PATHS:', log=logs / 'inspect.log')
    paths = json.loads(next(line.split('PACK_PATHS:', 1)[1] for line in output.splitlines() if line.startswith('PACK_PATHS:')))
    (artifact.parent / 'pack-paths.json').write_text(json.dumps(paths, indent=2))
    steam_paths = [p for p in paths if '/godotsteam/' in p or '/couch-games-sdk/steam/' in p or 'steam_backend' in p]
    files = [p for p in artifact.parent.rglob('*') if p.is_file()]
    if target == 'web' or not steam:
        forbidden = steam_paths if target == 'web' else [p for p in steam_paths if '/godotsteam/' in p]
        if forbidden or any(p.suffix in ('.so', '.dll', '.gdextension') for p in files):
            raise RuntimeError('Steam content or native library leaked into Steam-free package')
    else:
        if not any(p.endswith('godotsteam.gdextension') for p in paths) or not any('steam_backend.gd' in p for p in paths):
            raise RuntimeError('Native Steam package lacks its descriptor/adapter')
        # Verify the exported extension/runtime bytes against the verified archive,
        # including both x86_64 architecture choice and debug/release variants.
        for source in native_sources:
            candidates = [p for p in files if p.name == source.name]
            if len(candidates) != 1 or hashlib.sha256(candidates[0].read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
                raise RuntimeError(f'Missing or altered pinned runtime: {source.name}')
        if any(p.name == 'steam_appid.txt' for p in files) or any(p.endswith('steam_appid.txt') for p in paths):
            raise RuntimeError('App ID file leaked into package')
    return {'resource_count': len(paths), 'steam_resource_count': len(steam_paths),
            'native_dependencies': [p.name for p in native_sources]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--templates', required=True, type=Path)
    parser.add_argument('--godotsteam-zip', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--targets', nargs='+', choices=['linux', 'windows', 'web'], default=['linux', 'windows', 'web'])
    args = parser.parse_args()
    check_engine(args.godot)
    verify(args.templates, LOCK['templates'])
    verify(args.godotsteam_zip, STEAM_LOCK)
    output = args.output.resolve()
    # Require a fresh destination so old libraries cannot make an inspection pass.
    output.mkdir(parents=True, exist_ok=False)
    templates = output / '.templates'
    with zipfile.ZipFile(args.templates) as archive:
        wanted = ['linux_debug.x86_64', 'linux_release.x86_64', 'windows_debug_x86_64.exe',
                  'windows_debug_x86_64_console.exe', 'windows_release_x86_64.exe',
                  'windows_release_x86_64_console.exe', 'web_nothreads_debug.zip', 'web_nothreads_release.zip']
        for name in wanted:
            archive.extract('templates/' + name, templates)
    templates /= 'templates'
    inspector = output / '.inspector'
    inspector.mkdir()
    (inspector / 'project.godot').write_text('config_version=5\n')
    shutil.copy2(HERE / 'inspect.gd', inspector / 'inspect.gd')
    evidence = []
    for installed in [False, True]:
        project = output / ('.project-steam' if installed else '.project-shared')
        project.mkdir()
        stage_sdk(project)
        if installed:
            extract(args.godotsteam_zip, project)
            register_extensions(project)
        shutil.copy2(HERE / 'main.gd', project / 'main.gd')
        shutil.copy2(HERE / 'main.tscn', project / 'main.tscn')
        plugin = project / 'addons/package-filter'
        plugin.mkdir()
        shutil.copy2(HERE / 'export_plugin.gd', plugin / 'export_plugin.gd')
        (plugin / 'plugin.cfg').write_text('[plugin]\nname="SDK packaging filter"\ndescription="SDK fixture"\nauthor="Couch Games"\nversion="1"\nscript="export_plugin.gd"\n')
        (project / 'project.godot').write_text('''config_version=5
[application]
config/name="SDK package smoke"
run/main_scene="res://main.tscn"
config/use_custom_user_dir=true
config/custom_user_dir="%s/user"
[editor_plugins]
enabled=PackedStringArray("res://addons/package-filter/plugin.cfg")
[sdk_fixture]
expect_steam_extension=%s
[steam]
initialization/processes/initialize_on_startup=false
initialization/processes/embed_callbacks=false
[threading]
worker_pool/max_threads=4
[rendering]
renderer/rendering_method="gl_compatibility"
''' % (project.as_posix(), 'true' if installed else 'false'))
        logs = output / 'logs' / ('installed' if installed else 'absent')
        run([args.godot, '--headless', '--path', project, '--editor', '--import', '--quit'], project, log=logs / 'import.log')
        # Both source/editor and exported debug auto are exercised with installed extension.
        for mode in ['auto', 'mock', 'steam']:
            run([args.godot, '--headless', '--path', project, '--', '--mode=' + mode], project,
                'SDK_PACKAGE_SMOKE:', log=logs / ('editor-' + mode + '.log'))
        presets = []
        builds = []
        for target in args.targets:
            for variant in ['debug', 'release']:
                if target == 'web' and variant == 'debug':
                    continue  # Web release has identical script exclusions; native debug tests auto selection.
                template_name = (f'linux_{variant}.x86_64' if target == 'linux' else
                                 f'windows_{variant}_x86_64.exe' if target == 'windows' else f'web_nothreads_{variant}.zip')
                presets.append(preset(len(presets), target, templates / template_name, variant, False))
                builds.append((target, variant, False))
                if installed and target != 'web' and variant == 'release':
                    presets.append(preset(len(presets), target, templates / template_name, variant, True))
                    builds.append((target, variant, True))
        (project / 'export_presets.cfg').write_text('\n'.join(presets))
        for target, variant, steam_feature in builds:
            label = f'{target}-{variant}-' + ('steam' if installed else 'shared') + ('-feature' if steam_feature else '')
            artifact_dir = output / label
            artifact_dir.mkdir()
            suffix = {'linux': '.x86_64', 'windows': '.exe', 'web': '.html'}[target]
            artifact = artifact_dir / ('smoke' + suffix)
            run([args.godot, '--headless', '--path', project, '--export-' + variant,
                 target + '-' + variant + ('-feature' if steam_feature else ''), artifact], project, log=logs / (label + '-export.log'), timeout=180)
            if target == 'windows':
                # Godot copies a console companion from beside the custom template.
                # Check every Windows export, including builds on Linux, so a
                # missing wrapper cannot first surface as WinError 2 in smoke runs.
                wrapper = artifact.with_name(artifact.stem + '.console.exe')
                source = templates / f'windows_{variant}_x86_64_console.exe'
                if not wrapper.is_file() or wrapper.read_bytes() != source.read_bytes():
                    raise RuntimeError(f'Missing or altered pinned Windows console wrapper: {wrapper}')
            sources = []
            if installed and target != 'web':
                arch = 'linux64' if target == 'linux' else 'win64'
                extension = f'libgodotsteam.{"linux" if target == "linux" else "windows"}.template_{variant}.x86_64.{"so" if target == "linux" else "dll"}'
                sources = [project / 'addons/godotsteam' / arch / name for name in
                           [extension, 'libsteam_api.so' if target == 'linux' else 'steam_api64.dll']]
            record = {'artifact': label, 'inspection': inspect_package(args.godot, inspector, artifact, target, installed, sources, logs / label), 'execution': 'unexecuted on this host'}
            host = 'windows' if platform.system() == 'Windows' else 'linux'
            if target == host:
                if target == 'linux': artifact.chmod(0o755)
                for mode in ['auto', 'mock', 'steam']:
                    executable = artifact.with_name(artifact.stem + '.console.exe') if target == 'windows' else artifact
                    run([executable, '--headless', '--', '--mode=' + mode], artifact_dir,
                        'SDK_PACKAGE_SMOKE:', log=logs / (label + '-' + mode + '.log'))
                record['execution'] = 'native host smoke: auto/mock/explicit-steam failure'
            elif target == 'web':
                record['execution'] = 'requires browser runner; build and pack inspection only'
            evidence.append(record)
    (output / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('PACKAGE_INSPECTION_OK: ' + str(output))


if __name__ == '__main__':
    main()
