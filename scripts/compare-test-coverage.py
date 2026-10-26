#!/usr/bin/env python3
"""Compare unique production-source coverage against a fixed LLVM baseline.

The primary gate is relative covered-line loss. Optional LLVM JSON also reports
source regions and checks percentage-point loss, which is a different metric.
Neither denominator shrinkage nor newly covered code can hide lost coverage.
"""
import argparse
import json
from pathlib import Path


PREFIXES = ('app/Sources/', 'app/App/', 'shared/Sources/', 'ios/Sources/')


def production_path(filename, root):
    try:
        relative = Path(filename).relative_to(root).as_posix()
    except ValueError:
        return None
    if not relative.startswith(PREFIXES):
        return None
    if '/Tests/' in relative or '/TestsSupport/' in relative or '@__swiftmacro' in relative:
        return None
    return relative


def read_lines(paths, root):
    executable, covered = set(), set()
    for path in paths:
        current = None
        for line in Path(path).read_text().splitlines():
            if line.startswith('SF:'):
                current = production_path(line[3:], root)
            elif current and line.startswith('DA:'):
                number, count, *_ = line[3:].split(',')
                key = (current, int(number))
                executable.add(key)
                if int(count) > 0:
                    covered.add(key)
    return executable, covered


def read_regions(paths, root):
    executable, covered = set(), set()
    for path in paths:
        report = json.loads(Path(path).read_text())
        for data in report['data']:
            for function in data.get('functions', []):
                filenames = function['filenames']
                for region in function['regions']:
                    # LLVM kind 0 is a source region, excluding expansion/gap regions.
                    if len(region) < 8 or region[7] != 0:
                        continue
                    filename = production_path(filenames[region[5]], root)
                    if filename is None:
                        continue
                    key = (filename, *region[:4])
                    executable.add(key)
                    if region[4] > 0:
                        covered.add(key)
    return executable, covered


def comparison(before, after):
    executable, covered = before
    _, candidate = after
    if not executable or not covered:
        raise ValueError('The baseline must contain executable and covered production code.')
    lost = covered - candidate
    surviving = covered & candidate
    current = executable & candidate
    return {
        'baseline_executable': len(executable),
        'baseline_covered': len(covered),
        'candidate_covered_in_baseline': len(current),
        'retained_baseline_coverage': len(surviving),
        'lost_covered': len(lost),
        'relative_loss_percent': 100 * len(lost) / len(covered),
        'loss_percentage_points': 100 * len(lost) / len(executable),
        'baseline_percent': 100 * len(covered) / len(executable),
        'candidate_percent': 100 * len(current) / len(executable),
        'lost_locations': [list(location) for location in sorted(lost)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', required=True, type=Path)
    parser.add_argument('--candidate-root', required=True, type=Path)
    parser.add_argument('--baseline-lcov', required=True, nargs='+')
    parser.add_argument('--candidate-lcov', required=True, nargs='+')
    parser.add_argument('--baseline-json', nargs='+', default=[])
    parser.add_argument('--candidate-json', nargs='+', default=[])
    parser.add_argument('--max-line-loss-percent', type=float, default=2)
    parser.add_argument('--max-region-loss-points', type=float, default=2)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if bool(args.baseline_json) != bool(args.candidate_json):
        parser.error('Supply both JSON groups to compare source regions.')
    result = {'lines': comparison(
        read_lines(args.baseline_lcov, args.baseline_root),
        read_lines(args.candidate_lcov, args.candidate_root),
    )}
    if args.baseline_json:
        result['regions'] = comparison(
            read_regions(args.baseline_json, args.baseline_root),
            read_regions(args.candidate_json, args.candidate_root),
        )
    result['limits'] = {
        'relative_line_loss_percent': args.max_line_loss_percent,
        'region_loss_percentage_points': args.max_region_loss_points,
    }
    result['passes'] = (
        result['lines']['relative_loss_percent'] < args.max_line_loss_percent
        and result['lines']['loss_percentage_points'] < args.max_line_loss_percent
        and ('regions' not in result or
             result['regions']['loss_percentage_points'] < args.max_region_loss_points)
    )
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    for name in ('lines', 'regions'):
        if name in result:
            metric = result[name]
            print(f"{name}: {metric['baseline_covered']} -> "
                  f"{metric['candidate_covered_in_baseline']}; "
                  f"{metric['relative_loss_percent']:.4f}% baseline coverage lost "
                  f"({metric['loss_percentage_points']:.4f} percentage points)")
    raise SystemExit(0 if result['passes'] else 1)


if __name__ == '__main__':
    main()
