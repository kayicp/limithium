import { Actor, HttpAgent } from "@dfinity/agent";

export async function genActor(idlFactory, canisterId, _agent = null) {
	const agent = _agent ?? await HttpAgent.create();
	if (process.env.DFX_NETWORK !== 'ic') await agent.fetchRootKey();
	return Actor.createActor(idlFactory, { agent, canisterId });
}