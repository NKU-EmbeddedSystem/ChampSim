# SPEC CPU2017 configuration
export SPEC2017_ROOT="${HOME}/cpu2017"
export SPEC2017_CONFIG="linux64-amd64-gcc-fortify0.cfg"

# CPU2017 speed benchmarks only (single-stream, suitable for SimPoint profiling).
# Rate benchmarks (5XX_r) are multi-instance and not supported by the pipeline.
export SPEC2017_BENCHMARKS=(
  600.perlbench_s
  602.gcc_s
  603.bwaves_s
  605.mcf_s
  607.cactuBSSN_s
  619.lbm_s
  620.omnetpp_s
  621.wrf_s
  623.xalancbmk_s
  625.x264_s
  627.cam4_s
  628.pop2_s
  631.deepsjeng_s
  638.imagick_s
  641.leela_s
  644.nab_s
  648.exchange2_s
  649.fotonik3d_s
  654.roms_s
  657.xz_s
)
