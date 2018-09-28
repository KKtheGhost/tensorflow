#!/usr/bin/env python
"""Crosstool wrapper for compiling ROCm programs.

SYNOPSIS:
  crosstool_wrapper_driver_rocm [options passed in by cc_library()
                                or cc_binary() rule]

DESCRIPTION:
  This script is expected to be called by the cc_library() or cc_binary() bazel
  rules. When the option "-x rocm" is present in the list of arguments passed
  to this script, it invokes the hipcc compiler. Most arguments are passed
  as is as a string to --compiler-options of hipcc. When "-x rocm" is not
  present, this wrapper invokes gcc with the input arguments as is.
"""

from __future__ import print_function

__author__ = 'whchung@gmail.com (Wen-Heng (Jack) Chung)'

from argparse import ArgumentParser
import os
import subprocess
import re
import sys
import pipes

# Template values set by rocm_configure.bzl.
CPU_COMPILER = ('%{cpu_compiler}')
GCC_HOST_COMPILER_PATH = ('%{gcc_host_compiler_path}')

HIPCC_PATH = '%{hipcc_path}'
PREFIX_DIR = os.path.dirname(GCC_HOST_COMPILER_PATH)

def Log(s):
  print('gpus/crosstool: {0}'.format(s))


def GetOptionValue(argv, option):
  """Extract the list of values for option from the argv list.

  Args:
    argv: A list of strings, possibly the argv passed to main().
    option: The option whose value to extract, without the leading '-'.

  Returns:
    A list of values, either directly following the option,
    (eg., -opt val1 val2) or values collected from multiple occurrences of
    the option (eg., -opt val1 -opt val2).
  """

  parser = ArgumentParser()
  parser.add_argument('-' + option, nargs='*', action='append')
  args, _ = parser.parse_known_args(argv)
  if not args or not vars(args)[option]:
    return []
  else:
    return sum(vars(args)[option], [])


def GetHostCompilerOptions(argv):
  """Collect the -isystem, -iquote, and --sysroot option values from argv.

  Args:
    argv: A list of strings, possibly the argv passed to main().

  Returns:
    The string that can be used as the --compiler-options to hipcc.
  """

  parser = ArgumentParser()
  parser.add_argument('-isystem', nargs='*', action='append')
  parser.add_argument('-iquote', nargs='*', action='append')
  parser.add_argument('--sysroot', nargs=1)
  parser.add_argument('-g', nargs='*', action='append')
  parser.add_argument('-fno-canonical-system-headers', action='store_true')

  args, _ = parser.parse_known_args(argv)

  opts = ''

  if args.isystem:
    opts += ' -isystem ' + ' -isystem '.join(sum(args.isystem, []))
  if args.iquote:
    opts += ' -iquote ' + ' -iquote '.join(sum(args.iquote, []))
  if args.g:
    opts += ' -g' + ' -g'.join(sum(args.g, []))
  #if args.fno_canonical_system_headers:
  #  opts += ' -fno-canonical-system-headers'
  if args.sysroot:
    opts += ' --sysroot ' + args.sysroot[0]

  return opts

def GetHipccOptions(argv):
  """Collect the -hipcc_options values from argv.

  Args:
    argv: A list of strings, possibly the argv passed to main().

  Returns:
    The string that can be passed directly to hipcc.
  """

  parser = ArgumentParser()
  parser.add_argument('-hipcc_options', nargs='*', action='append')

  args, _ = parser.parse_known_args(argv)

  if args.hipcc_options:
    options = _update_options(sum(args.hipcc_options, []))
    return ' '.join(['--'+a for a in options])
  return ''


def InvokeHipcc(argv, log=False):
  """Call hipcc with arguments assembled from argv.

  Args:
    argv: A list of strings, possibly the argv passed to main().
    log: True if logging is requested.

  Returns:
    The return value of calling os.system('hipcc ' + args)
  """

  host_compiler_options = GetHostCompilerOptions(argv)
  hipcc_compiler_options = GetHipccOptions(argv)
  opt_option = GetOptionValue(argv, 'O')
  m_options = GetOptionValue(argv, 'm')
  m_options = ''.join([' -m' + m for m in m_options if m in ['32', '64']])
  include_options = GetOptionValue(argv, 'I')
  out_file = GetOptionValue(argv, 'o')
  depfiles = GetOptionValue(argv, 'MF')
  defines = GetOptionValue(argv, 'D')
  defines = ''.join([' -D' + define for define in defines])
  undefines = GetOptionValue(argv, 'U')
  undefines = ''.join([' -U' + define for define in undefines])
  std_options = GetOptionValue(argv, 'std')
  hipcc_allowed_std_options = ["c++11"]
  std_options = ''.join([' -std=' + define
      for define in std_options if define in hipcc_allowed_std_options])

  # The list of source files get passed after the -c option. I don't know of
  # any other reliable way to just get the list of source files to be compiled.
  src_files = GetOptionValue(argv, 'c')

  if len(src_files) == 0:
    return 1
  if len(out_file) != 1:
    return 1

  opt = (' -O2' if (len(opt_option) > 0 and int(opt_option[0]) > 0)
         else ' -g')

  includes = (' -I ' + ' -I '.join(include_options)
              if len(include_options) > 0
              else '')

  # Unfortunately, there are other options that have -c prefix too.
  # So allowing only those look like C/C++ files.
  src_files = [f for f in src_files if
               re.search('\.cpp$|\.cc$|\.c$|\.cxx$|\.C$', f)]
  srcs = ' '.join(src_files)
  out = ' -o ' + out_file[0]

  hipccopts = ' '
  hipccopts += ' ' + hipcc_compiler_options
  hipccopts += undefines
  hipccopts += defines
  hipccopts += std_options
  hipccopts += m_options

  if depfiles:
    # Generate the dependency file
    depfile = depfiles[0]
    cmd = (HIPCC_PATH + ' ' + hipccopts +
           host_compiler_options +
           ' ' + GCC_HOST_COMPILER_PATH +
           ' -I .' + includes + ' ' + srcs + ' -M -o ' + depfile)
    if log: Log(cmd)
    exit_status = os.system(cmd)
    if exit_status != 0:
      return exit_status

  cmd = (HIPCC_PATH + ' ' + hipccopts +
         host_compiler_options + ' -fPIC' +
         ' ' + GCC_HOST_COMPILER_PATH +
         ' -I .' + opt + includes + ' -c ' + srcs + out)

  # TODO(zhengxq): for some reason, 'gcc' needs this help to find 'as'.
  # Need to investigate and fix.
  cmd = 'PATH=' + PREFIX_DIR + ':$PATH ' + cmd
  if log: Log(cmd)
  return os.system(cmd)


def main():
  # ignore PWD env var
  os.environ['PWD']=''

  parser = ArgumentParser()
  parser.add_argument('-x', nargs=1)
  parser.add_argument('--rocm_log', action='store_true')
  parser.add_argument('-pass-exit-codes', action='store_true')
  args, leftover = parser.parse_known_args(sys.argv[1:])

  if args.x and args.x[0] == 'rocm':
    if args.rocm_log: Log('-x rocm')
    leftover = [pipes.quote(s) for s in leftover]
    if args.rocm_log: Log('using hipcc')
    return InvokeHipcc(leftover, log=args.rocm_log)

  # XXX use hipcc to link
  if args.pass_exit_codes:
    gpu_compiler_flags = [flag for flag in sys.argv[1:]
                               if not flag.startswith(('-pass-exit-codes'))]

    # special handling for $ORIGIN
    # - guard every argument with ''
    modified_gpu_compiler_flags = []
    for flag in gpu_compiler_flags:
      modified_gpu_compiler_flags.append("'" + flag + "'")

    if args.rocm_log: Log('Link with hipcc: %s' % (' '.join([HIPCC_PATH] + modified_gpu_compiler_flags)))
    return subprocess.call([HIPCC_PATH] + modified_gpu_compiler_flags)

  # Strip our flags before passing through to the CPU compiler for files which
  # are not -x rocm. We can't just pass 'leftover' because it also strips -x.
  # We not only want to pass -x to the CPU compiler, but also keep it in its
  # relative location in the argv list (the compiler is actually sensitive to
  # this).
  cpu_compiler_flags = [flag for flag in sys.argv[1:]
                             if not flag.startswith(('--rocm_log'))]

  # XXX: SE codes need to be built with gcc, but need this macro defined
  cpu_compiler_flags.append("-D__HIP_PLATFORM_HCC__")

  return subprocess.call([CPU_COMPILER] + cpu_compiler_flags)

if __name__ == '__main__':
  sys.exit(main())