#!/usr/bin/env python3
"""Validate the actual Xcode-processed release metadata before a long app build."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_KEY = 'fuIqCE9IUmecB8Hjj44IcBz2XrVX/fMxenjhsTJIglI='

def verify(path, version, build, revision):
    assert re.fullmatch(r'\d+\.\d+\.\d+', version)
    assert isinstance(build, int) and build > 0
    assert re.fullmatch(r'[0-9a-f]{40}', revision)
    info = plistlib.loads(path.read_bytes())
    expected = dict(CFBundleIdentifier='wovenmatter.desktop', CFBundleShortVersionString=version,
        CFBundleVersion=str(build), WovenMatterSourceRevision=revision,
        SUFeedURL='https://github.com/wovenmatter/wovenmatter/releases/latest/download/appcast.xml',
        SUPublicEDKey=PUBLIC_KEY, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
    for key, value in expected.items():
        actual = info.get(key)
        if type(actual) is not type(value) or actual != value:
            raise ValueError(f'Release metadata {key}: expected {value!r}, got {actual!r}')

def preflight(root, version, build, revision, source_plist=None):
    # Use the real target's merged project/target Release metadata settings and
    # source plist. This target has no code, dependencies or build scripts: only
    # Xcode's normal ProcessInfoPlistFile operation runs. Nothing is launched.
    project_path = root / 'app/WovenMatter.xcodeproj/project.pbxproj'
    project = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(project_path)]))
    objects = project['objects']
    target = next(o for o in objects.values() if o['isa'] == 'PBXNativeTarget' and o['name'] == 'WovenMatter')
    def release_settings(owner):
        configs = objects[owner['buildConfigurationList']]['buildConfigurations']
        return next(objects[c]['buildSettings'] for c in configs if objects[c]['name'] == 'Release')
    settings = dict(release_settings(objects[project['rootObject']]), **release_settings(target))
    wanted = {'GENERATE_INFOPLIST_FILE', 'PRODUCT_NAME', 'PRODUCT_BUNDLE_IDENTIFIER',
              'MACOSX_DEPLOYMENT_TARGET', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION', 'SDKROOT'}
    metadata = {k: v for k, v in settings.items() if k.startswith('INFOPLIST_') or k in wanted}
    metadata['INFOPLIST_FILE'] = str(source_plist or root / 'app' / metadata['INFOPLIST_FILE'])
    with tempfile.TemporaryDirectory(prefix='wovenmatter-release-metadata-') as temporary:
        folder = Path(temporary)
        probe = folder / 'Metadata.xcodeproj'
        probe.mkdir()
        metadata.update(CODE_SIGNING_ALLOWED='NO', VALIDATE_PRODUCT='NO', ALWAYS_SEARCH_USER_PATHS='NO',
                        CONFIGURATION_BUILD_DIR=str(folder / 'products'))
        # The project is deliberately metadata-only; it cannot build the app,
        # sign code, contact a provider, install anything or submit notarization.
        keys = [f'{i:024X}' for i in range(1, 10)]
        project_id, group, products, product, target_id, pcfg, tcfg, pcl, tcl = keys
        configurations = lambda config: dict(isa='XCConfigurationList', buildConfigurations=[config],
            defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
        graph = {
            project_id: dict(isa='PBXProject', buildConfigurationList=pcl, compatibilityVersion='Xcode 14.0',
                mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target_id]),
            group: dict(isa='PBXGroup', children=[products], sourceTree='<group>'),
            products: dict(isa='PBXGroup', children=[product], name='Products', sourceTree='<group>'),
            product: dict(isa='PBXFileReference', explicitFileType='wrapper.application',
                path='Woven Matter.app', sourceTree='BUILT_PRODUCTS_DIR'),
            target_id: dict(isa='PBXNativeTarget', buildConfigurationList=tcl, buildPhases=[], buildRules=[],
                dependencies=[], name='MetadataProbe', productName='Woven Matter',
                productReference=product, productType='com.apple.product-type.application'),
            pcfg: dict(isa='XCBuildConfiguration', buildSettings={}, name='Release'),
            tcfg: dict(isa='XCBuildConfiguration', buildSettings=metadata, name='Release'),
            pcl: configurations(pcfg), tcl: configurations(tcfg),
        }
        (probe / 'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1', classes={},
            objectVersion='56', objects=graph, rootObject=project_id)))
        subprocess.run(['xcodebuild', '-quiet', '-project', str(probe), '-target', 'MetadataProbe',
            '-configuration', 'Release', f'MARKETING_VERSION={version}', f'CURRENT_PROJECT_VERSION={build}',
            f'WOVENMATTER_SOURCE_REVISION={revision}', 'build'], check=True)
        verify(folder / 'products/Woven Matter.app/Contents/Info.plist', version, build, revision)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['preflight', 'verify'])
    parser.add_argument('version')
    parser.add_argument('build', type=int)
    parser.add_argument('revision')
    parser.add_argument('--plist', type=Path)
    args = parser.parse_args()
    if args.mode == 'preflight':
        preflight(ROOT, args.version, args.build, args.revision)
    else:
        if args.plist is None:
            parser.error('verify requires --plist')
        verify(args.plist, args.version, args.build, args.revision)
    print(f'Release metadata verified: {args.version} build {args.build} at {args.revision}.')
