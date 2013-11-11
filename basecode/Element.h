/**********************************************************************
** This program is part of 'MOOSE', the
** Messaging Object Oriented Simulation Environment.
**           Copyright (C) 2003-2013 Upinder S. Bhalla. and NCBS
** It is made available under the terms of the
** GNU Lesser General Public License version 2.1
** See the file COPYING.LIB for the full notice.
**********************************************************************/
#ifndef _ELEMENT_H
#define _ELEMENT_H

class SrcFinfo;
class FuncOrder;

/**
 * Base class for all object lookups.
 * Provides the MOOSE interface so that it handles messaging, class info,
 * and basic fields. Does not do data.
 */
class Element
{
	friend void testSync();
	friend void testAsync();
	friend void testStandaloneIntFire();
	friend void testSynapse();
	friend void testSyncArray( unsigned int, unsigned int, unsigned int );
	friend void testSparseMsg();
	public:
		/**
		 * This is the main constructor, used by Shell::innerCreate
		 * which makes most Elements. Also used to create base
		 * Elements to init the simulator in main.cpp.
		 * Id is the Id of the new Element
		 * Cinfo is the class
		 * name is its name
		 * numData is the number of data entries, defaults to a singleton.
		 * The isGlobal flag specifies whether the created objects should
		 * be replicated on all nodes, or partitioned without replication. 
		 */
		Element( Id id, const Cinfo* c, const string& name );

		/**
		 * Destructor
		 */
		virtual ~Element();

		/**
		 * Copier
		 */
		virtual Element* copyElement( Id newParent, Id newId, 
					unsigned int n, bool toGlobal ) const = 0;
		/////////////////////////////////////////////////////////////////
		// Information access fields
		/////////////////////////////////////////////////////////////////

		/**
		 * Returns name of Element
		 */
		const string& getName() const;
		
		/**
		 * Changes name of Element
		 */
		void setName( const string& val );

		/// Returns number of data entries
		virtual unsigned int numData() const = 0;

		/// Returns number of field entries for specified data
		virtual unsigned int numField( unsigned int rawIndex ) const = 0;

		/**
		 * Returns the Id on this Elm
		 */
		Id id() const;

		/**
		 * True if this is a FieldElement having an array of fields 
		 * on each data entry. Clearly not true for the base Element.
		 */
		virtual bool hasFields() const = 0;

		/////////////////////////////////////////////////////////////////
		// data access stuff
		/////////////////////////////////////////////////////////////////

		/**
		 * Looks up specified field data entry. On regular objects just
		 * returns the data entry specified by the rawIndex. 
		 * On FieldElements like synapses, does a second lookup on the
		 * field index.
		 * Note that the index is NOT a
		 * DataId: it is instead the raw index of the data on the current
		 * node. Index is also NOT the character offset, but the index
		 * to the data array in whatever type the data may be.
		 *
		 * The DataId has to be filtered through the nodeMap to
		 * find a) if the entry is here, and b) what its raw index is.
		 *
		 * Returns 0 if either index is out of range.
		 */
		virtual char* data( unsigned int rawIndex, 
						unsigned int fieldIndex = 0 ) const = 0;

		/**
		 * Changes the number of entries in the data. Not permitted for
		 * FieldElements since they are just fields on the data.
		 */
		virtual void resize( unsigned int newNumData ) = 0;

		/**
		 * Changes the number of fields on the specified data entry.
		 * Doesn't do anything for the regular Element.
		 */
		virtual void resizeField( 
				unsigned int rawIndex, unsigned int newNumField ) = 0;

		/////////////////////////////////////////////////////////////////


		/** 
		 * Pushes the Msg mid onto the list.
		 * The position on the list does not matter.
		 * 
		 */
		void addMsg( ObjId mid );

		/**
		 * Removes the specified msg from the list.
		 */
		void dropMsg( ObjId mid );
		
		/**
		 * Clears out all Msgs on specified BindIndex. Used in Shell::set
		 */
		void clearBinding( BindIndex b );

		/**
		 * Pushes back the specified Msg and Func pair into the properly
		 * indexed place on the msgBinding_ vector.
		 */
		void addMsgAndFunc( ObjId mid, FuncId fid, BindIndex bindIndex );

		/**
		 * gets the Msg/Func binding information for specified bindIndex.
		 * This is a vector.
		 * Returns 0 on failure.
		 */
		const vector< MsgFuncBinding >* getMsgAndFunc( BindIndex b ) const;

		/**
		 * Returns true if there are one or more Msgs on the specified
		 * BindIndex
		 */
		bool hasMsgs( BindIndex b ) const;

		/**
		 * Utility function for printing out all fields and their values
		 */
		void showFields() const;

		/**
		 * Utility function for traversing and displaying all messages
		 */
		void showMsg() const;

		/**
		 * Rebuild digested message array; traverse all messages to do so
		 */
		void digestMessages();

		/**
		 * Inner function that adds targets to a single function in the
		 * MsgDigest
		 */
		void putTargetsInDigest(
					   	unsigned int srcNum, const MsgFuncBinding& mfb,
						const FuncOrder& fo );

		/**
		 * Gets the class information for this Element
		 */
		const Cinfo* cinfo() const;

		/**
		 * Destroys all Elements in tree, being efficient about not
		 * trying to traverse through clearing messages to doomed Elements.
		 * Assumes tree includes all child elements.
		 * Typically the Neutral::destroy function builds up this tree
		 * and then calls this function.
		 */
		static void destroyElementTree( const vector< Id >& tree );


	/////////////////////////////////////////////////////////////////////
	// Utility functions for message traversal
	/////////////////////////////////////////////////////////////////////
	
		/**
		 * Raw lookup into MsgDigest vector. One for each MsgSrc X ObjEntry.
		 */
		const vector< MsgDigest >& msgDigest( unsigned int index ) const;

		/**
		 * Returns the binding index of the specified entry.
		 * Returns ~0 on failure.
		 */
		 unsigned int findBinding( MsgFuncBinding b ) const;

		 /**
		  * Returns all incoming Msgs.
		  */
		 const vector< ObjId >& msgIn() const;

		/**
		 * Returns the first Msg that calls the specified Fid, 
		 * on current Element.
		 * Returns 0 on failure.
		 */
		 ObjId findCaller( FuncId fid ) const;

		/** 
		 * More general function. Fills up vector of ObjIds that call the
		 * specified Fid on current Element. Returns # found
		 */
		unsigned int getInputMsgs( vector< ObjId >& caller, FuncId fid)
		 	const;

		/**
		 * Fills in vector of Ids connected to this Finfo on
		 * this Element. Returns # found
		 */
		unsigned int getNeighbours( vector< Id >& ret, const Finfo* finfo )
			const;

		/**
		 * Fills in vector, each entry of which identifies the src and 
		 * dest fields respectively. 
		 * Src field is local and identified by BindIndex
		 * Dest field is a FuncId on the remote Element.
		 */
		unsigned int getFieldsOfOutgoingMsg( 
			ObjId mid, vector< pair< BindIndex, FuncId > >& ret ) const;

		/**
		 * zombieSwap: replaces the Cinfo of the zombie.
		 */
		void zombieSwap( const Cinfo* newCinfo );

	protected:
		/// Used by derived classes to zero out Cinfo during destruction.
		void clearCinfoAndMsgs();

	private:
		/**
		 * Fills in vector of Ids receiving messages from this SrcFinfo. 
		 * Returns # found
		 */
		unsigned int getOutputs( vector< Id >& ret, const SrcFinfo* finfo )
			const;

		/**
		 * Fills in vector of Ids sending messeges to this DestFinfo on
		 * this Element. Returns # found
		 */
		unsigned int getInputs( vector< Id >& ret, const DestFinfo* finfo )
			const;

		string name_; /// Name of the Element.

		Id id_; /// Stores the unique identifier for Element.

		/**
		 * Class information
		 */
		const Cinfo* cinfo_;

		/**
		 * Message vector. This is the low-level messaging information.
		 * Contains info about incoming as well as outgoing Msgs.
		 */
		vector< ObjId > m_;

		/**
		 * Binds an outgoing message to its function.
		 * Each index (BindIndex) gives a vector of MsgFuncBindings,
		 * which are just pairs of ObjId, FuncId.
		 * SrcFinfo keeps track of the BindIndex to look things up.
		 * Note that a single BindIndex may refer to multiple Msg/Func
		 * pairs. This means that a single MsgSrc may dispatch data 
		 * through multiple msgs using a single 'send' call.
		 */
		vector< vector < MsgFuncBinding > > msgBinding_;

		/**
		 * Digested vector of message traversal sets. Each set has a
		 * Func and element to lead off, followed by a list of target
		 * indices and fields.
		 * The indexing is like this:
		 * msgDigest_[ numSrcMsgs * DataId + srcMsgIndex ][ func# ]
		 * So we look up a vector of MsgDigests, each with a unique func,
		 * based on both the DataId and the message number. This is designed
		 * so that if we expand the number of data entries we don't have
		 * to redo the ordering.
		 */
		vector< vector < MsgDigest > > msgDigest_;

		/**
		 * Digested targets from all source Msgs. Indexed as
		 * msgTargets_[ numSrcMsgs * DataId + srcMsgIndex ]
		 */
		// vector< vector< Eref > > msgTargets_;
};

#endif // _ELEMENT_H
