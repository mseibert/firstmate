#!/usr/bin/env bash
# Assigned here and only consumed by a library the local gate does not follow.
cross_file_only=1
outer() {
  (
    # Defined here and only invoked by a library the local gate does not follow.
    cross_file_helper() {
      printf 'ok\n'
    }
    printf 'hi\n'
  )
}
outer
