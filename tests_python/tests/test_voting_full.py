"""
This tests the migration from PROTO_A to PROTO_B. It also tests
the test chain in the testing phase of the voting process, and the
bootstrap heuristics.
"""

import time
import os
import json
import pytest
from tools import utils, constants, paths


ERROR_PATTERN = r"Uncaught|registered|error"
BLOCKS_PER_VOTING_PERIOD = 20
POLLING_TIME = 5
BAKING_RATE = 1

PROTO_A = constants.CARTHAGE
PROTO_A_DAEMON = constants.CARTHAGE_DAEMON
PROTO_A_PATH = f"proto_{PROTO_A_DAEMON.replace('-','_')}"
PROTO_B = constants.ALPHA
PROTO_B_DAEMON = constants.ALPHA_DAEMON

PARAMETERS_FILE = (f'{paths.TEZOS_HOME}src/{PROTO_A_PATH}/parameters/'
                   'test-parameters.json')
assert os.path.isfile(PARAMETERS_FILE), (f'{PARAMETERS_FILE}'
                                         ' cannot be found; please first run'
                                         ' `make` in TEZOS_HOME.')
with open(PARAMETERS_FILE) as f:
    PARAMETERS = dict(json.load(f))
    PARAMETERS["time_between_blocks"] = [str(BAKING_RATE), "0"]
    PARAMETERS["blocks_per_voting_period"] = BLOCKS_PER_VOTING_PERIOD


def node_params(threshold=0):
    return ['--max-latency', '2', '--chain-stuck-delay', '10',
            '--sync-polling-period', '1', '--bootstrap-threshold',
            str(threshold), '--connections', '500', '--enable-testchain']


@pytest.mark.vote
@pytest.mark.slow
@pytest.mark.baker
@pytest.mark.testchain
@pytest.mark.incremental
class TestVotingFull:

    def test_add_tmp_bootstrap_node(self, sandbox):
        """ launch tmp nodes just to bootstrap all other ones """
        sandbox.add_node(10, params=node_params(0))
        sandbox.add_node(11, params=node_params(0))

    def test_activate_proto_a(self, sandbox):
        sandbox.client(10).activate_protocol_json(PROTO_A, PARAMETERS)

    def test_add_tmp_bootstrap_baker(self, sandbox):
        """ Launch a temporary baker so that 10 and 11 keep broadcasting
            heads to the future joining nodes and help them bootstrap """
        sandbox.add_baker(10, 'bootstrap5', proto=PROTO_A_DAEMON)

    def test_add_initial_nodes(self, sandbox):
        """ We launch nodes with non-null bootstrap-threshold.
            This is to test the bootstrap heuristics with the testchain. """
        sandbox.add_node(0, params=node_params(2))
        sandbox.add_node(1, params=node_params(2))
        sandbox.add_node(2, params=node_params(2))
        sandbox.add_node(3, params=node_params(2))

    @pytest.mark.timeout(20)
    def test_bootstrap(self, sandbox):
        clients = sandbox.all_clients()
        for client in clients:
            client.bootstrapped()

    def test_remove_tmp_bootstrap_nodes(self, sandbox):
        """These temp noddes are no longer needed"""
        sandbox.rm_baker(10, proto=PROTO_A_DAEMON)
        sandbox.rm_node(10)
        sandbox.rm_node(11)

    def test_add_baker(self, sandbox):
        sandbox.add_baker(0, 'bootstrap5', proto=PROTO_A_DAEMON)

    def test_client_knows_proto_b(self, sandbox):
        client = sandbox.client(0)
        protos = client.list_protocols()
        assert PROTO_B in protos

    @pytest.mark.timeout(60)
    def test_wait_second_proposal_period(self, sandbox):
        """Polling until the second proposal period, avoid bug
           that prevents to make proposals in the first proposal period"""
        client = sandbox.client(0)
        while client.get_level() <= BLOCKS_PER_VOTING_PERIOD:
            time.sleep(POLLING_TIME)

    def test_proposal_period(self, sandbox):
        client = sandbox.client(0)
        assert client.get_current_period_kind() == 'proposal'

    def test_submit_proto_b_proposal(self, sandbox, session):
        client = sandbox.client(0)
        proposals = client.submit_proposals('bootstrap1', [PROTO_B])
        session['prop_hash'] = proposals.operation_hash

    def test_wait_for_operation_inclusion(self, sandbox, session):
        client = sandbox.client(0)
        client.wait_for_inclusion(session['prop_hash'])

    def test_check_proto_b_proposed(self, sandbox):
        client = sandbox.client(0)
        proposals = client.get_proposals()
        assert PROTO_B in [proto for (proto, _) in proposals]

    @pytest.mark.timeout(60)
    def test_wait_for_voting_period(self, sandbox):
        client = sandbox.client(0)
        while client.get_current_period_kind() != 'testing_vote':
            time.sleep(POLLING_TIME)

    def test_delegates_vote_proto_b(self, sandbox):
        client = sandbox.client(0)
        for i in range(1, 5):
            client.submit_ballot(f'bootstrap{i}', PROTO_B, 'yay')

    @pytest.mark.timeout(60)
    def test_wait_for_testing(self, sandbox):
        for client in sandbox.all_clients():
            while client.get_current_period_kind() != 'testing':
                time.sleep(POLLING_TIME)

    def test_make_sure_all_clients_testing_period(self, sandbox):
        for client in sandbox.all_clients():
            assert client.get_current_period_kind() == 'testing'

    def test_start_baker_testchain(self, sandbox):
        sandbox.add_baker(3, 'bootstrap4', proto=PROTO_B_DAEMON,
                          params=['--chain', 'test'])

    def test_testchain_rpc(self, sandbox):
        for client in sandbox.all_clients():
            assert client.get_current_period_kind() == 'testing'
            main_id = client.rpc('get', 'chains/main/chain_id')
            test_id = client.rpc('get', 'chains/test/chain_id')
            assert test_id != main_id

    def test_testchains_bootstrapped(self, sandbox):
        """All testchains must be bootstrapped, since they inherited
           the bootstrap status of the parent chain"""
        for client in sandbox.all_clients():
            assert client.is_bootstrapped(chain='test')

    def test_testchain_transfer(self, sandbox):
        client = sandbox.client(0)
        client.transfer(10, 'bootstrap1', 'bootstrap2', chain='test')

    def test_testchain_progress(self, sandbox):
        """Make sure testchain is moving forward"""
        client = sandbox.client(0)
        level_testchain_before = client.get_level(chain='test')
        assert utils.check_level_greater_than(client,
                                              level_testchain_before + 1,
                                              chain='test')

    def test_reactivate_all_delegates(self, sandbox):
        """Delegates may have become unactive"""
        client = sandbox.client(0)
        for i in range(1, 5):
            account = f'bootstrap{i}'
            client.set_delegate(account, account)

    @pytest.mark.timeout(60)
    def test_wait_for_promotion_vote_period(self, sandbox):
        client = sandbox.client(0)
        while client.get_current_period_kind() != 'promotion_vote':
            client.rpc('get', '/chains/main/blocks/head/header/shell')
            time.sleep(2)

    def test_vote_in_promotion_phase(self, sandbox):
        client = sandbox.client(0)
        for i in range(1, 5):
            client.submit_ballot(f'bootstrap{i}', PROTO_B, 'yay')

    def test_start_proto_b_baker(self, sandbox):
        """Proto_B will be elected, launch a new Proto_B baker"""
        sandbox.add_baker(1, 'bootstrap3', proto=PROTO_B_DAEMON)

    @pytest.mark.timeout(60)
    def test_wait_for_new_proposal_period(self, sandbox):
        client = sandbox.client(1)
        while client.get_level() <= 5 * BLOCKS_PER_VOTING_PERIOD:
            client.rpc('get', '/chains/main/blocks/head/header/shell')
            time.sleep(POLLING_TIME)

    @pytest.mark.timeout(40)
    def test_all_nodes_run_proto_b(self, sandbox):
        all_have_proto = False
        while not all_have_proto:
            clients = sandbox.all_clients()
            all_have_proto = all(client.get_protocol() == PROTO_B
                                 for client in clients)
            time.sleep(POLLING_TIME)

    def test_stop_old_bakers(self, sandbox):
        """Stop old protocol baker, and test chain baker"""
        sandbox.rm_baker(0, PROTO_A_DAEMON)
        sandbox.rm_baker(3, PROTO_B_DAEMON)
        time.sleep(1)

    def test_new_chain_progress(self, sandbox):
        client = sandbox.client(0)
        level_before = client.get_level()
        assert utils.check_level_greater_than(client, level_before + 1)

    @pytest.mark.xfail
    def test_check_logs(self, sandbox):
        assert utils.check_logs(sandbox.logs, ERROR_PATTERN)
